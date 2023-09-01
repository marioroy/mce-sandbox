
// libprimesieve (parallel segmented variant):
//   C demonstration by Mario Roy, 2023-08-18
//
// This requires the libprimesieve C API.
//   https://github.com/kimwalisch/primesieve
//
// Build (clang or gcc; on macOS install gcc-12 via homebrew):
//   gcc -o primes3 -O3 -fopenmp primes3.c -lprimesieve -lm
//   gcc -o primes3 -O3 -fopenmp -march=x86-64-v3 primes3.c -lprimesieve -lm
//
// Usage:
//   OMP_NUM_THREADS=8 ./primes3 [ N [ N ] [ -p ] ]  default 1 1000
//   OMP_NUM_THREADS=8 ./primes3 100 -p        print primes found
//   OMP_NUM_THREADS=8 ./primes3 87233720365000000 87233720368547757
//   OMP_NUM_THREADS=8 ./primes3 18446744073000000000 18446744073709551609
//   OMP_NUM_THREADS=8 ./primes3 1e+16 1.00001e+16

#include <primesieve.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#ifdef _OPENMP
#include <omp.h>
#else
#define omp_get_thread_num() 0
#endif

static const int FLUSH_LIMIT = 65536 - 24;

static void show_progress(uint64_t start, uint64_t high, uint64_t stop)
{
    static int last_completed = -1;

    int completed = (double)(high - start) / (stop - start) * 100;
    if (last_completed != completed) {
        if (completed > 99) completed = 99;
        last_completed = completed;
        fprintf(stderr, "  %d%%\r", completed);
        fflush(stderr);
    }
}

static inline void printint(uint64_t value, int flush_only)
{
    // Print integer to static buffer; empty buffer automatically when full.
    // Before exiting, call printint(0,1) to empty the buffer only and return.
    //
    // OMP_NUM_THREADS=4 ./primes 1e10 -p >/dev/null  #  4.6GB
    //   14.070s before, unbuffered
    //   10.012s buffered
    //
    static char buf[65536];
    static int written = 0;

    if (written && (written > FLUSH_LIMIT || flush_only)) {
        fwrite(buf, written, 1, stdout);
        written = 0;
    }
    if (flush_only) {
        fflush(stdout);
        return;
    }
    // end of buffer logic

    char c;
    int s = written, e = written;
    uint64_t temp;

    // base10 to string conversion
    do {
        temp = value / 10;
        buf[s] = (char) ('0' + value - 10 * temp);
        s++;
    } while ((value = temp));

    // increment the number of characters including linefeed
    written += s - e + 1;  buf[s] = '\n';

    // reverse the string in place
    while (--s > e) {
        c = buf[s];
        buf[s] = buf[e];
        buf[e] = c;
        e++;
    }
}

static const uint64_t LIMIT_MAX  = 18446744073709551609UL; // 2^64-1-6
static const int      SIEVE_SIZE = 9609600;

void primesieve(uint64_t start, uint64_t stop, int print_flag)
{
    // disable threading in the library as we're running threads here
    primesieve_set_num_threads(1);

    int64_t step_sz = SIEVE_SIZE * 19;
    if      ( stop >= 1e+19 ) { step_sz *= 8; }
    else if ( stop >= 1e+18 ) { step_sz *= 7; }
    else if ( stop >= 1e+17 ) { step_sz *= 6; }
    else if ( stop >= 1e+16 ) { step_sz *= 5; }
    else if ( stop >= 1e+15 ) { step_sz *= 4; }
    else if ( stop >= 1e+14 ) { step_sz *= 3; }
    else if ( stop >= 1e+13 ) { step_sz *= 2; }
    else if ( stop >= 1e+12 ) { step_sz *= 1; }

    int64_t num_chunks = (stop - start + step_sz) / step_sz;
    int64_t count = 0;

    #pragma omp parallel for ordered schedule(static, 1) reduction(+:count)
    for (int64_t chunk_id = 0; chunk_id < num_chunks; chunk_id++)
    {
        uint64_t low = start + (step_sz * chunk_id);
        uint64_t high = low + step_sz - 1;

        // Check also high < low in case addition overflowed.
        if (high > stop || high < low) high = stop;

        if (omp_get_thread_num() == 0 && stop > 2000000000L && !print_flag)
            show_progress(start, high, stop);

        if (print_flag) {
///
// Error: "primesieve_iterator: cannot generate primes > 2^64"
// https://github.com/kimwalisch/primesieve/issues/138
// Reduce start/stop values, but not forget the last unsigned 64-bit prime.
//
// Why it happens? "Calling primesieve_next_prime() after 18446744073709551557
// would generate a prime greater than 2^64 which primesieve doesn't support,
// hence this causes an error."
///
            uint64_t include_last_prime;
            if (low <= 18446744073709551557UL && high >= 18446744073709551557UL)
                include_last_prime = 18446744073709551557UL;
            else
                include_last_prime = 0UL;

            if (low  > 18446744073709551556UL) low  = 18446744073709551556UL;
            if (high > 18446744073709551556UL) high = 18446744073709551556UL;

            primesieve_iterator it;
            primesieve_init(&it);
            primesieve_jump_to(&it, low, high);

            uint64_t prime = primesieve_next_prime(&it);

            #pragma omp ordered
            while (prime <= high) {
                printint(prime, 0);
                prime = primesieve_next_prime(&it);
            }
            if (include_last_prime)
                printint(include_last_prime, 0);
        }
        else {
            count += primesieve_count_primes(low, high);
        }
    }

    if (print_flag)
        printint(0UL,1);  // flush buffer only
    else
        fprintf(stderr, "\rPrimes found: %ld\n", count);
}

int main(int argc, char** argv)
{
    uint64_t start = 1UL, stop = 1000UL;
    int loff = -1, print_flag = 0;

    // check for print option
    if (argc > 1 && strcmp(argv[argc-1], "-p") == 0) {
        print_flag = 1;
        argc--;
    }

    // check if range is given -- two integers
    if (argc > 2) {
        loff = 2;
        if (strlen(argv[1]) > 20 || strtold(argv[1], NULL) > LIMIT_MAX) {
            fprintf(stderr, "Start exceeds %lu 2^64-1-6.\n", LIMIT_MAX);
            return 1;
        }
        start = (uint64_t) strtold(argv[1], NULL);
    }
    else if (argc > 1) {
        loff = 1;
    }

    // check for start of range or limit
    if (loff > 0) {
        if (strlen(argv[loff]) > 20 || strtold(argv[loff], NULL) > LIMIT_MAX) {
            fprintf(stderr, "Limit exceeds %lu 2^64-1-6.\n", LIMIT_MAX);
            return 1;
        }
        stop = (uint64_t) strtold(argv[loff], NULL);
    }

    // count primes between start and stop, inclusively
    if (start < 1 || stop < start) {
        fprintf(stderr, "Invalid integer or range.\n");
        return 1;
    }
    else {
        double tstart = omp_get_wtime();
        primesieve(start, stop, print_flag);
        double tend = omp_get_wtime();
        fprintf(stderr, "Seconds: %0.3lf\n", tend - tstart);
    }

    return 0;
}

