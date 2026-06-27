#include <atomic> 
#include <semaphore> 
#include <iostream>
#include <thread> 

std::binary_semaphore s1(0);
std::binary_semaphore s2(0);
std::atomic<int*> ptr = new int(42);

void thread1_op () {
    int* old_address = ptr.load();
    s2.release();
    s1.acquire();
    int* new_address = new int(0);
    int* ptr_before_cas = ptr.load();
    // GROUND TRUTH (known because we wrote thread2_op): this IS ABA.
    // The address matches old_address, so the CAS will succeed but
    // no in-program check can prove ABA from the pointer alone, because
    // free+realloc leaves the pointer value unchanged.
    bool ok = ptr.compare_exchange_strong(old_address, new_address); 
    std::cout << "old_address:    " << old_address << "\n";
    std::cout << "ptr before CAS: " << ptr_before_cas << "\n";
    std::cout << "CAS succeeded:  " << ok << "\n";
}

void thread2_op() {
    s2.acquire();
    delete ptr.load();
    ptr = new int(67);
    s1.release();
}

int main() {
    std::thread t1(thread1_op);
    std::thread t2(thread2_op);
    t1.join();
    t2.join();
    return 0;
}
