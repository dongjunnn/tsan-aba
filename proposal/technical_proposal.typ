= TSan-ABA: Dynamic Detection of the ABA Problem in ThreadSanitizer

*UROP Technical Proposal*

#line(length: 100%)

== Approach

The proposal provided the generation-counter approach. This is named "layer B" and it attempts to capture ABA in all memory regions.
There is another layer proposed, named "layer A" which specifically targets heap memory.

#table(
  columns: 4,
  align: left,
  [*Layer*], [*Mechanism*], [*Scope*], [*Confidence*],
  [*A*], [Monotonic `alloc_epoch` per heap chunk], [Heap-reuse ABA via `malloc`/`free`], [HIGH (proven identity change)],
  [*B*], [Per-atomic 64-bit generation counter], [All atomic-CAS code, any allocator], [MEDIUM (value cycle, possibly benign)]
)

When both fire on the same CAS, only the Layer A (HIGH-confidence) diagnostic is emitted.

#line(length: 100%)

== Layer A — Allocation Epoch Tracking

*Data structures.* Add one `u64 alloc_epoch` field to TSan's existing chunk metadata in `tsan_mman.cc`. One global `atomic<u64> g_aba_epoch` initialized to 1.

*Allocator hooks* (modify existing TSan `malloc`/`free` interceptors):

```c
malloc(size):
    chunk = tsan_internal_alloc(size)
    chunk.alloc_epoch = g_aba_epoch.fetch_add(1)
    return chunk.user_ptr

free(ptr):
    chunk = GetBlockBegin(ptr)
    chunk.alloc_epoch = 0                  // mark dead (defensive)
    tsan_internal_free(ptr)
```

*Atomic-load instrumentation:*

```c
on atomic_load of pointer P from atomic address A:
    chunk = GetBlockBegin(P)
    if chunk == null: return               // not heap → Layer B handles it
    tls_cache.insert(A, { ptr: P, epoch: chunk.alloc_epoch })
```

*CAS-success instrumentation:*

```c
on successful CAS at atomic address A with expected value P:
    entry = tls_cache.lookup(A)
    if entry == null: return               // no prior load recorded
    chunk = GetBlockBegin(P)
    if chunk == null or chunk.alloc_epoch != entry.epoch:
        emit HIGH-confidence ABA diagnostic
```

*Why this works.* The monotonic global epoch guarantees a unique allocation identity across the program's lifetime. This means no two live allocations ever share an epoch. Any free-and-reallocation at the same address forces an epoch change. The CAS check compares the pointer's current allocation identity against the identity observed at load and a mismatch is proof of identity change.

*Estimated Cost.* One 8 byte field per chunk header; one atomic increment per `malloc`; one `GetBlockBegin` lookup per instrumented atomic load and per successful CAS. `GetBlockBegin` is an existing TSan allocator-API operation.

*Scope limit.* Layer A is blind when memory does not flow through `malloc`/`free` like object pools, slab allocators, arena allocators, stack-allocated nodes. Layer B covers this gap.

Layer A does not require the user to change their code implementation and there is no false positives.

#line(length: 100%)

== Custom Allocators -> same mechanism for data segmenet and mmap? need read more

High-performance concurrent code frequently bypasses standard `malloc`/`free` in favour of memory pools, arenas, or slab allocators to reduce lock contention and allocation latency. TSan's `GetBlockBegin` only resolves pointers that flow through its own allocator. It is blind to internal slot reuse within a custom allocator. From TSan's perspective, the entire pool slab is one big allocation whose epoch never changes, even as individual slots are handed out and recycled hundreds of times. This produces false negatives.

=== Solution: Minimal Annotation API

```c
void __tsan_aba_pool_alloc(void *ptr);
void __tsan_aba_pool_free(void *ptr);
```

The user calls `__tsan_aba_pool_alloc` when a slot is handed out from the pool, and `__tsan_aba_pool_free` when a slot is returned to the pool. This is two lines inside the allocator implementation — not at every call site.

```cpp
void* MyPool::allocate() {
    void* p = pop_from_freelist();
    __tsan_aba_pool_alloc(p);     // one new line
    return p;
}

void MyPool::deallocate(void* p) {
    __tsan_aba_pool_free(p);      // one new line
    push_to_freelist(p);
}
```

=== Internal Design

- `__tsan_aba_pool_alloc(ptr)` fetches a new epoch from `g_aba_epoch` (the same global counter used by Layer A) and inserts it into the map via `AddrHashMap::Handle` with `create=true`.
- `__tsan_aba_pool_free(ptr)` removes the entry via `Handle` with `remove=true`. The entry is deleted, not zeroed, so the map does not grow unboundedly over the lifetime of a long-running program.

The lookup path is unified with Layer A through a single helper:
```c
GetPointerEpoch(ptr):
  block = GetBlockBegin(ptr)
  if block != null:
    return block.alloc_epoch        // standard heap path
  handle = AddrHashMap.lookup(ptr)
  if handle found:
    return handle.epoch             // custom allocator path
  return 0                          // unmanaged — skip check silently
```

The atomic load and CAS instrumentation is unchanged from Layer A — it calls `GetPointerEpoch` and the rest of the logic is identical. No new instrumentation hooks are needed.

=== Precision Guarantee

The custom allocator path inherits Layer A's zero-false-positive guarantee. If a pointer is in the map, the epoch comparison is exact — a mismatch is proof of slot reuse. If a pointer is not in the map (unannotated allocator), `GetPointerEpoch` returns 0 and the check is silently skipped. The result is a false negative, not a false positive.

=== Scope and Honest Limitations

#table(
  columns: 3,
  align: left,
  [*Allocator type*], [*Coverage*], [*User effort*],
  [Standard `malloc`/`free`], [Automatic], [None],
  [`operator new` / `delete`], [Automatic (TSan intercepts these)], [None],
  [jemalloc, tcmalloc, mimalloc], [Automatic if they call `malloc` internally (most do)], [None],
  [Custom pool / slab / arena], [Covered with annotation], [Two lines in allocator impl],
  [Unannotated custom allocator], [Not covered — false negatives], [—]
)

The unannotated case is a documented limitation, not a correctness failure. ABA bugs in unannotated allocators will be missed, not incorrectly reported.

#line(length: 100%)

== Shared TLS Cache

64-entry, 4-way set-associative (16 sets × 4 ways), per thread. Single lookup serves both layers. LRU within each set.

```cpp
struct CacheEntry {
    void* atomic_addr;      // key
    void* loaded_ptr;       // value observed
    u64   alloc_epoch;      // Layer A — 0 if non-heap
    u64   counter_value;    // Layer B
    u32   timestamp;        // for LRU
};
```

The cache is what associates atomic _loads_ with their corresponding _CAS sites_ — the central correctness challenge the brief identified.

#line(length: 100%)

== LLVM Pass Integration

TSan instruments atomic operations at compile time by walking the program's LLVM IR
and inserting calls to runtime functions at each atomic site. The ABA detector extends
this existing pass — it does not add a separate parallel pass.

For the MVP, two instrumentation hooks are added:

+ *Atomic load* — after every `atomic_load` on a pointer-typed value, the pass
  inserts a call to `__tsan_aba_record_load(addr, value)`. This records the loaded
  pointer and its current allocation epoch into the thread-local TLS cache.

+ *Atomic CAS* — after every `atomic_compare_exchange` that succeeds, the pass
  inserts a call to `__tsan_aba_check_cas(addr, expected)`. This looks up the TLS
  cache entry for `addr` and compares the cached epoch against the current epoch of
  the pointer. A mismatch emits a HIGH-confidence ABA diagnostic.

No instrumentation is added to atomic stores or RMW operations for the MVP. Those are Layer B concerns (archived).

*Static filter applied at pass time:*

- *Type filter*: only pointer-typed and pointer-sized atomics are instrumented by
  default. `atomic<int>`, `atomic<bool>`, sequence counters, and flags are skipped.
  This eliminates the vast majority of atomic operations in typical programs, keeping
  overhead low. The flag `aba_check_integers=1` re-enables instrumentation of
  integer-typed atomics for completeness testing.

#line(length: 100%)

== MVP
Layer A heap detection only:
- Add `u64 alloc_epoch` to TSan's chunk header in `tsan_mman.cc`
- Add global `atomic<u64> g_aba_epoch` initialized to 1
- Hook malloc interceptor to stamp epoch on allocation
- Hook free interceptor to zero epoch on deallocation
- Add TLS cache (64-entry, 4-way set-associative, 16 sets × 4 ways, LRU)
- Extend LLVM instrumentation pass with three hooks: atomic load, CAS pre-check, CAS post-success
- Implement GetPointerEpoch helper
- Implement diagnostic reporter emitting a TSan-style warning

#line(length: 100%)

== Regression Tests

I will start with simple tests. They will involve just pointers to demonstrate the different scenarios with ABA. This will be done before moving onto more complex concurrent data structures. 



Each test is a self-contained C++ program compiled under three configurations and
verified by a shell script that checks stderr for the presence or absence of the
ABA warning string. The script exits non-zero if any test produces unexpected output,
making it suitable as a CI gate.

*True positive tests — detector must fire:*

#table(
  columns: 4,
  align: left,
  [*Test*], [*Structure*], [*Threads*], [*Expected*],
  [TP1], [Treiber stack, `malloc`/`free` nodes], [2], [HIGH ABA warning],
  [TP2], [Michael-Scott queue, `malloc`/`free` nodes], [3], [HIGH ABA warning]
)

ABA is forced deterministically using semaphore barriers that choreograph the exact
load → free → reallocate → CAS interleaving. Tests do not rely on timing or stress.

*True negative tests — detector must stay silent:*

#table(
  columns: 4,
  align: left,
  [*Test*], [*Structure*], [*Protection*], [*Expected*],
  [TN1], [Treiber stack], [Hazard pointers], [Zero warnings],
  [TN2], [Treiber stack], [Epoch-based reclamation], [Zero warnings],
  [TN3], [Atomic integer counter], [N/A (not a pointer)], [Zero warnings]
)

TN3 verifies the type filter: `atomic<int>` must never be instrumented.

*MVP acceptance criterion:* TP1 and TP2 fire on every run. TN1, TN2, and TN3
produce zero warnings. If any of these fail, the implementation is incorrect and
benchmarking does not proceed.

#line(length: 100%)

== Benchmarks and Metrics

*Benchmark workload:*

Treiber stack stress test — 4 threads (2 pushers, 2 poppers), 1,000,000 operations
total, `malloc`/`free` nodes. Run for at least 5 seconds under TSan to avoid
startup/teardown noise dominating the measurement. Median of 5 runs reported.

*Three build configurations:*

#table(
  columns: 3,
  align: left,
  [*Config*], [*Flags*], [*Purpose*],
  [Baseline], [`-O1 -g`], [Uninstrumented reference],
  [TSan only], [`-fsanitize=thread -O1 -g`], [TSan cost without ABA],
  [TSan + ABA], [`-fsanitize=thread,aba -O1 -g`], [Full MVP cost]
)

*Metrics reported:*

#table(
  columns: 3,
  align: left,
  [*Metric*], [*Formula*], [*Target*],
  [True positive rate], [TP tests firing / total TP tests], [100%],
  [False positive rate], [TN tests firing / total TN tests], [0%],
  [Performance overhead], [`(TSan+ABA time / TSan-only time) − 1.0`], [< 15%],
  [Memory overhead], [Peak RSS (TSan+ABA) − Peak RSS (TSan-only)], [< 10%]
)

Performance overhead is measured as wall time. Memory overhead is measured via
`/usr/bin/time -v` (field: "Maximum resident set size"). Both are reported as
median over 5 runs with standard deviation to show stability.

The performance target of < 15% is relative to baseline TSan, not to uninstrumented
code. TSan itself imposes 5–15× slowdown; Layer A adds only the cost of one
`GetPointerEpoch` lookup per instrumented atomic load and per successful CAS.

#line(length: 100%)

== Stack Detection -> kiv

#line(length: 100%)

== ARCHIVED KIV NOT FOR MVP
=== Layer B — Per-Atomic Generation Counter

*Data structure.* A global counter array: 65,536 buckets, each cache-line padded (64 bytes) to avoid false sharing → ~4 MB total. Indexed by `hash(atomic_address) mod 65536` using a bit-permutation hash.

```cpp
struct alignas(64) Bucket {
    atomic<u64> counter;
    u8 padding[56];
};
Bucket counter_array[65536];
```

*Atomic-store / exchange / RMW instrumentation:*

```c
on atomic_store / atomic_exchange / atomic_fetch_* at address A:
    counter_array[hash(A)].counter.fetch_add(1, relaxed)
```

*Atomic-load instrumentation* (combined with Layer A's load hook into one runtime call):

```c
on atomic_load from A:
    tls_cache.insert(A, {
        ptr:     loaded_value,
        epoch:   chunk.alloc_epoch,                    // Layer A
        counter: counter_array[hash(A)].counter.load() // Layer B
    })
```

*CAS-success instrumentation:*

```c
on successful CAS at A:
    entry = tls_cache.lookup(A)
    if entry == null: return
    current = counter_array[hash(A)].counter.load()
    delta = current - entry.counter
    if delta >= 2:
        emit MEDIUM-confidence ABA diagnostic (with delta value)
```

*Why delta >= 2.* Delta >= 2 means at least two writes occurred, which requires the value to have changed and changed back (or further changes that allowed the CAS expected value to match again) i.e. the A→B→A signature. Setting the threshold at 1 would produce massive FPs on any contended atomic.

*Cost.* One relaxed-atomic increment per atomic store (the hot path); one load on atomic load and successful CAS. The cache-line padding prevents counter contention on adjacent buckets.

*Trade-off.* Hash collisions cause two distinct atomic addresses to share a bucket. FPs (unrelated activity cycles our counter) or FNs (our activity is masked by the other atomic's activity). Bounded by bucket count; quantified in evaluation. Lazy materialization (Tier-2 optimization) reduces the effective load on the table by only inserting addresses that have been observed in a CAS.