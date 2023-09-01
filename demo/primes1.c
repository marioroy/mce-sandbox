
// Algorithm3 (parallel segmented variant):
//   C demonstration by Mario Roy, 2023-08-18
//
// Xuedong Luo:
//   A practical sieve algorithm for finding prime numbers.
//   ACM Volume 32 Issue 3, March 1989, Pages 344-346 
//   https://dl.acm.org/doi/pdf/10.1145/62065.62072
//   http://dl.acm.org/citation.cfm?doid=62065.62072
//
//   "Based on the sieve of Eratosthenes, a faster and more compact
//    algorithm is presented for finding all primes between 2 and N.
//    Avoid all composites that have 2 or 3 as one of their prime
//    factors (where i is odd)."
//
//   { 0, 5, 7, 11, 13, ... 3i + 2, 3(i + 1) + 1, ..., N }
//     0, 1, 2,  3,  4, ... list indices (0 is not used)
//
// Build (clang or gcc; on macOS install gcc-12 via homebrew):
//   gcc -o primes1 -O3 -fopenmp primes1.c -lm
//   gcc -o primes1 -O3 -fopenmp -march=x86-64-v3 primes1.c -lm
//
// Usage:
//   OMP_NUM_THREADS=8 ./primes1 [ N [ N ] [ -p ] ]  default 1 1000
//   OMP_NUM_THREADS=8 ./primes1 100 -p        print primes found
//   OMP_NUM_THREADS=8 ./primes1 87233720365000000 87233720368547757
//   OMP_NUM_THREADS=8 ./primes1 18446744073000000000 18446744073709551609
//   OMP_NUM_THREADS=8 ./primes1 1e+16 1.00001e+16

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>

#ifdef _OPENMP
#include <omp.h>
#else
#define omp_get_thread_num() 0
#endif

typedef unsigned char byte_t;

static const byte_t _POPCNT_BYTE[256] = {
    0,1,1,2,1,2,2,3,1,2,2,3,2,3,3,4,1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,
    1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,
    1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,
    2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
    1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,
    2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
    2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
    3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,4,5,5,6,5,6,6,7,5,6,6,7,6,7,7,8
};

static int64_t popcount(const byte_t *bytearray, int64_t size)
{
    int64_t asize, i, count = 0;

    if (bytearray == 0 || size == 0)
        return count;

    if (size > 8) {
      #ifdef __LP64__
        static const uint64_t m1  = UINT64_C(0x5555555555555555);
        static const uint64_t m2  = UINT64_C(0x3333333333333333);
        static const uint64_t m4  = UINT64_C(0x0f0f0f0f0f0f0f0f);
        static const uint64_t h01 = UINT64_C(0x0101010101010101);

        const uint64_t *a = (uint64_t *) bytearray;
        uint64_t b;

        asize = (size + 7) / 8 - 1;

        for (i = 0; i < asize; i++) {
            b = a[i];
            b =  b       - ((b >> 1)  & m1);
            b = (b & m2) + ((b >> 2)  & m2);
            b = (b       +  (b >> 4)) & m4;
            count += (b * h01) >> 56;
        }

        i = asize * 8;

      #else
        static const uint32_t m1  = UINT32_C(0x55555555);
        static const uint32_t m2  = UINT32_C(0x33333333);
        static const uint32_t m4  = UINT32_C(0x0f0f0f0f);
        static const uint32_t h01 = UINT32_C(0x01010101);

        const uint32_t *a = (uint32_t *) bytearray;
        uint32_t b;

        asize = (size + 3) / 4 - 1;

        for (i = 0; i < asize; i++) {
            b = a[i];
            b =  b       - ((b >> 1)  & m1);
            b = (b & m2) + ((b >> 2)  & m2);
            b = (b       +  (b >> 4)) & m4;
            count += (b * h01) >> 24;
        }

        i = asize * 4;

      #endif
    }
    else
        i = 0;

    for (; i < size; i++)
        count += _POPCNT_BYTE[bytearray[i]];

    return count;
}

static const int _UNSET_BIT[8] = {
    (~(1 << 0) & 0xff), (~(1 << 1) & 0xff),
    (~(1 << 2) & 0xff), (~(1 << 3) & 0xff),
    (~(1 << 4) & 0xff), (~(1 << 5) & 0xff),
    (~(1 << 6) & 0xff), (~(1 << 7) & 0xff)
};

#define CLRBIT(s,i) s[(int64_t)(i) >> 3] &= _UNSET_BIT[(i) & 7]
#define GETBIT(s,i) s[(int64_t)(i) >> 3] &  (1 << ((i) & 7))
#define SETBIT(s,i) s[(int64_t)(i) >> 3] |= (1 << ((i) & 7))

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

static void output_primes(
    const byte_t *s, uint64_t start, uint64_t low, uint64_t high,
    int64_t M, uint64_t n_off )
{
    if (start <= 2 && low <= 2 && high >= 2)
        printint(2UL, 0);
    if (start <= 3 && low <= 3 && high >= 3)
        printint(3UL, 0);

    for (int64_t i = 1; i <= M; i += 2) {
        if (GETBIT(s, i))
            printint(n_off + (3UL * i + 2), 0);
        if (GETBIT(s, i + 1))
            printint(n_off + (3UL * (i + 1) + 1), 0);
    }
}

// Step size is a multiple of 510510 or 9699690 for the pre-sieve logic.
// Primes (2)(3), the app pre-sieves (5)(7)(11)(13)(17) and >= 1e12 (19).
// 2*3*5*7*11*13*17 = 510510 * 19 = 9699690.

static const uint64_t LIMIT_MAX = 18446744073709551609UL; // 2^64-1-6

void practicalsieve(uint64_t start, uint64_t stop, int print_flag)
{
    // Adjust start to a multiple of 6, substract 6, and add 1.
    //
    // Corner case: We substract 6 regardless. For example:
    // Segment (start = 102, stop = 140) prime start_adj = 103 is skipped
    // unless substracting 6; start_adj = 97, n_off = start_adj - 1.
    //
    // Index 0 is cleared, not used. Index 1 is cleared, outside segment.
    // { 0, 101, 103, 107, ..., n_off + 3i + 2, n_off + 3(i + 1) + 1, ..., N }
    // { 0,   0, 103, 107, ..., n_off + 3i + 2, n_off + 3(i + 1) + 1, ..., N }

    uint64_t start_adj = (start > 5)
        ? start - (start % 6) - 6 + 1
        : 1;

    int64_t step_sz = (stop < 1e12) ? 510510 * 12 : 9699690;
    if      ( stop >= 1e+19 ) { step_sz *= 8; }
    else if ( stop >= 1e+18 ) { step_sz *= 7; }
    else if ( stop >= 1e+17 ) { step_sz *= 6; }
    else if ( stop >= 1e+16 ) { step_sz *= 5; }
    else if ( stop >= 1e+15 ) { step_sz *= 4; }
    else if ( stop >= 1e+14 ) { step_sz *= 3; }
    else if ( stop >= 1e+13 ) { step_sz *= 2; }
    else if ( stop >= 1e+12 ) { step_sz *= 1; }

    //===================================================================
    // Compute is_prime <= q. This enables threads to process faster.
    //===================================================================

    int64_t q = (int64_t) sqrt((double) stop) / 3;
    int64_t mem_sz_q = (q + 2 + 7) / 8;
    byte_t *is_prime = (byte_t *) malloc(mem_sz_q);
    memset(is_prime, 0xff, mem_sz_q);
    CLRBIT(is_prime, 0);

    int64_t c = 0, k = 1, t = 2, j, ij;

    // clear small composites <= q
    for (int64_t i = 1; i <= q; i++) {
        k  = 3 - k, c += 4 * k * i, j = c;
        ij = 2 * i * (3 - k) + 1, t += 4 * k;
        if (GETBIT(is_prime, i)) {
            while (j <= q) {
                CLRBIT(is_prime, j);
                j += ij, ij = t - ij;
            }
        }
    }

    //===================================================================
    // if stop < 1e12
    //    Pre-sieve 5, 7, 11, 13, and 17 (i = 1 through 5).
    // else
    //    Pre-sieve 5, 7, 11, 13, 17, and 19 (i = 1 through 6).
    //===================================================================

    int64_t sieve_sz = step_sz / 3;
    int64_t mem_sz_p = (sieve_sz + 2 + 7) / 8;
    byte_t *pre_sieve = (byte_t *) malloc(mem_sz_p);
    memset(pre_sieve, 0xff, mem_sz_p);
    CLRBIT(pre_sieve, 0);

    int64_t c_off, j_off = (start_adj - 1) / 3; 
    c = 0, k = 1, t = 2;

    for (int64_t i = 1; i <= (stop < 1e12 ? 5 : 6); i++) {
        k  = 3 - k, c += 4 * k * i, j = c;
        ij = 2 * i * (3 - k) + 1, t += 4 * k;

        // skip numbers before start_adj
        if (j < j_off) {
            j += (j_off - j) / t * t + ij;
            ij = t - ij;
            if (j < j_off)
                j += ij, ij = t - ij;
        }
        // clear composites (j <= sieve_sz)
        c_off = j - j_off;
        while ((c_off >> 3) < mem_sz_p) {
            CLRBIT(pre_sieve, c_off);
            j += ij, ij = t - ij;
            c_off = j - j_off;
        }
    }

    //===================================================================
    // if stop < 1e12
    // ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    // 1. At this point, i = 6, c = 96, k = 2, and t = 34.
    //    Threads will not need to process i = 1 through 5.
    // 2. Clear bits for 5, 7, 11, 13, and 17 including bit 0.
    //    The thread processing the first chunk will undo this.
    // else
    // ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    // 1. At this point, i = 7, c = 120, k = 1, and t = 38.
    //    Threads will not need to process i = 1 through 6.
    // 2. Clear bits for 5, 7, 11, 13, 17, and 19 including bit 0.
    //    The thread processing the first chunk will undo this.
    //===================================================================

    if (start_adj == 1) {
        pre_sieve[0] = (stop < 1e12) ? 0xc0 : 0x80;
    }

    // clear bits greater than "sieve_sz"
    int64_t i = mem_sz_p * 8 - (sieve_sz + 1);
    while (i) {
        CLRBIT(pre_sieve, mem_sz_p * 8 - i);
        i--;
    }

    int64_t num_chunks = (stop - start_adj + step_sz) / step_sz;
    int64_t count = 0;

    if (start <= 2 && stop >= 2) count++;
    if (start <= 3 && stop >= 3) count++;

    #pragma omp parallel for ordered schedule(static, 1) reduction(+:count)
    for (int64_t chunk_id = 0; chunk_id < num_chunks; chunk_id++)
    {
        uint64_t low = start_adj + (step_sz * chunk_id);
        uint64_t high = low + step_sz - 1;

        // Check also high < low in case addition overflowed.
        if (high > stop || high < low) high = stop;

        if (omp_get_thread_num() == 0 && stop > 2000000000L && !print_flag)
            show_progress(start_adj, high, stop);

        //===============================================================
        // Practical sieve algorithm.
        //===============================================================

        int64_t q = (int64_t) sqrt((double) high) / 3;
        int64_t M = (high - low + (high & 1)) / 3;
        int64_t M2 = high / 3;
        uint64_t n_off = low - 1;
        int64_t j_off = n_off / 3;

        int64_t mem_sz = (M + 2 + 7) / 8;
        byte_t *sieve = (byte_t *) malloc(mem_sz);

        // copy pre-sieved data into sieve
        // fix byte 0 if starting at 1 (has primes 5,7,11,13,17,19,23)
        memcpy(sieve, pre_sieve, mem_sz);
        if (low == 1) sieve[0] = 0xfe;

        // clear composites less than "start" value
        if (low == start_adj && n_off + ((3 * 1 + 1) | 1) < start) {
            CLRBIT(sieve, 1);
            if (n_off + ((3 * 2 + 1) | 1) < start)
                CLRBIT(sieve, 2);
        }

        // clear composites greater than "stop" value
        if (high == stop) {
            int64_t i = mem_sz * 8 - (M + 2);
            while (i) {
                CLRBIT(sieve, mem_sz * 8 - i);
                i--;
            }
            if (n_off + ((3 * (M + 1) + 1) | 1) > stop) {
                CLRBIT(sieve, M + 1);
                if (n_off + ((3 * M + 1) | 1) > stop)
                    CLRBIT(sieve, M);
            }
        }

        int64_t c, k, t, j, ij;

        if (stop < 1e12) {
         // sieving begins with 19 (i = 6)
            c = 96, k = 2, t = 34;
        } else {
         // sieving begins with 23 (i = 7)
            c = 120, k = 1, t = 38;
        }

        for (int64_t i = (stop < 1e12 ? 6 : 7); i <= q; i++) {
            k  = 3 - k, c += 4 * k * i, j = c;
            ij = 2 * i * (3 - k) + 1, t += 4 * k;

            if (GETBIT(is_prime, i)) {
                // skip numbers before this block
                if (j < j_off) {
                    j += (j_off - j) / t * t + ij;
                    ij = t - ij;
                    if (j < j_off)
                        j += ij, ij = t - ij;
                }
                // clear composites
                while (j <= M2) {
                    CLRBIT(sieve, j - j_off);
                    j += ij, ij = t - ij;
                }
            }
        }

        //===============================================================
        // Output or count primes found.
        //===============================================================

        if (print_flag) {
            #pragma omp ordered
            output_primes(sieve, start, low, high, M, n_off);
        }
        else {
            count += popcount(sieve, mem_sz);
        }

        free((void *) sieve);
        sieve = NULL;
    }

    if (print_flag)
        printint(0UL,1);  // flush buffer only
    else
        fprintf(stderr, "\rPrimes found: %lld\n", count);

    free((void *) pre_sieve);
    pre_sieve = NULL;
    free((void *) is_prime);
    is_prime = NULL;
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
            fprintf(stderr, "Start exceeds %llu 2^64-1-6.\n", LIMIT_MAX);
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
            fprintf(stderr, "Limit exceeds %llu 2^64-1-6.\n", LIMIT_MAX);
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
        practicalsieve(start, stop, print_flag);
        double tend = omp_get_wtime();
        fprintf(stderr, "Seconds: %0.3lf\n", tend - tstart);
    }

    return 0;
}

