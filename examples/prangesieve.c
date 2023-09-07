
// Algorithm3 (parallel range variant).
//   C demonstration by Mario Roy, 2023-09-03
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
//   gcc -o prangesieve -I../src -O3 -fopenmp prangesieve.c -lm
//   gcc -o prangesieve -I../src -O3 -fopenmp -march=x86-64-v3 prangesieve.c -lm
//
// Usage:
//   prangesieve [ N [ N ] [ -p ] ]  default 1 1000
//   prangesieve 100 -p              print primes found
//   prangesieve 1e+10 1.1e+10       count primes found
//   prangesieve 87233720365000000 87233720368547757
//   prangesieve 1e12 1.1e12

#include <omp.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include "bits.h"

byte_t *makeprimes(uint64_t stop)
{
   int64_t q = (int64_t) sqrt((double) stop) / 3;
   int64_t mem_sz = (q + 2 + 7) / 8;
   int64_t i, c = 0, k = 1, t = 2, j, ij;

   byte_t *array = (byte_t *) malloc(mem_sz);
   if (array == NULL) {
      fprintf(stderr, "error: failed to allocate primes array.\n");
      exit(2);
   }
   memset(array, 0xff, mem_sz);
   CLRBIT(array, 0);

   // clear small composites <= q
   for (i = 1; i <= q; i++) {
      k = 3 - k, c += 4 * k * i, j = c;
      ij = 2 * i * (3 - k) + 1, t += 4 * k;
      if (GETBIT(array, i)) {
         while (j <= q) {
            CLRBIT(array, j);
            j += ij, ij = t - ij;
         }
      }
   }

   return array;
}

void prangesieve(uint64_t start, uint64_t stop, int print_flag)
{
   // adjust start to a multiple of 6; then subtract 6 and add 1
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

   int64_t num_segments = (stop - start_adj + step_sz) / step_sz;
   byte_t *is_prime = makeprimes(stop);
   int64_t count = 0;

   int64_t M = (stop - start_adj + (stop & 1)) / 3;
   uint64_t n_off = start_adj - 1;
   int64_t j_off = n_off / 3;
   int64_t mem_sz = (M + 2 + 7) / 8 + (num_segments - 1);
   byte_t  *sieve;

   sieve = (byte_t *) malloc(mem_sz);
   if (sieve == NULL) {
      fprintf(stderr, "error: failed to allocate sieve array.\n");
      exit(2);
   }
   memset(sieve, 0xff, mem_sz);
   CLRBIT(sieve, 0);

   // clear bits less than start
   if (n_off + ((3 * 1 + 1) | 1) < start) {
      CLRBIT(sieve, 1);
      if (n_off + ((3 * 2 + 1) | 1) < start)
         CLRBIT(sieve, 2);
   }

   // clear bits greater than stop
   int64_t i = (mem_sz - (num_segments - 1)) * 8 - (M + 2);
   while (i) {
      CLRBIT(sieve, mem_sz * 8 - i);
      i--;
   }
   if (n_off + ((3 * (M + 1) + 1) | 1) > stop) {
      CLRBIT(sieve, M + 1 + (num_segments - 1) * 8);
      if (n_off + ((3 * M + 1) | 1) > stop)
         CLRBIT(sieve, M + (num_segments - 1) * 8);
   }

   // create JJ, MM lists; clear one-byte padding between segments
   int64_t *JJ = malloc(num_segments * sizeof(int64_t)); JJ[0] = 0;
   int64_t *MM = malloc(num_segments * sizeof(int64_t));
   int64_t off = 0;

   for (int64_t n = 0; n < num_segments - 1; n++) {
      uint64_t low  = start_adj + (step_sz * n);
      uint64_t high = low + step_sz - 1;
      if (high > stop || high < low) high = stop;
      int64_t m = high / 3;
      JJ[n + 1] = m - j_off;
      MM[n + 0] = m - j_off;
      for (int i = 1; i <= 8; i++)
         CLRBIT(sieve, m - j_off + i + off);
      off += 8;
   }

   MM[num_segments - 1] = M + 2;
   int64_t cc = 0, kk = 1, tt = 2;

   #pragma omp parallel for schedule(static, 1)
   for (int64_t n = 0; n < num_segments; n++) {
      uint64_t low  = start_adj + (step_sz * n);
      uint64_t high = low + step_sz - 1;
      if (high > stop || high < low) high = stop;

      int64_t q = (int64_t) sqrt((double) high) / 3;
      int64_t m = high / 3;
      int64_t c = cc, k = kk, t = tt, j, ij;
      int64_t j_off2 = JJ[n];

      // account for one-byte padding (8 bits) between segments
      // this guarantees that writes are safe between adjacent threads
      int64_t s_off = j_off - n * 8;

      for (int64_t i = 1; i <= q; i++) {
         k  = 3 - k, c += 4 * k * i, j = c;
         ij = 2 * i * (3 - k) + 1, t += 4 * k;
         if (GETBIT(is_prime, i)) {
            // skip numbers before this segment
            if (j < j_off + j_off2) {
               j += (j_off + j_off2 - j) / t * t + ij;
               ij = t - ij;
               if (j < j_off + j_off2)
                  j += ij, ij = t - ij;
            }
            // clear composites
            while (j <= m) {
               CLRBIT(sieve, j - s_off);
               j += ij, ij = t - ij;
            }
         }
      }
   }

   free((void *) JJ); JJ = NULL;
   free((void *) is_prime); is_prime = NULL;

   if (start <= 2 && stop >= 2) count++;
   if (start <= 3 && stop >= 3) count++;

   count += popcount(sieve, mem_sz);

   if (print_flag) {
      if (start <= 2 && stop >= 2) printf("2\n");
      if (start <= 3 && stop >= 3) printf("3\n");
      int64_t off = 0, num = MM[0], ind = 0;
      for (i = 1; i <= M; i += 2) {
         if (i >= num)
            off += 8, num = MM[++ind];
         if (GETBIT(sieve, i + off))
            printf("%lu\n", n_off + (3 * i + 2));
         if (GETBIT(sieve, i + 1 + off))
            printf("%lu\n", n_off + (3 * (i + 1) + 1));
      }
   }

   free((void *) MM); MM = NULL;
   free((void *) sieve); sieve = NULL;

   fprintf(stderr, "Primes found: %ld\n", count);
}

int main(int argc, char** argv)
{
   // find primes in range, inclusively
   uint64_t start = 1, stop = 1000;
   int print_flag = 0;

   // check for print option (last option specified)
   if (argc > 1 && strcmp(argv[argc-1], "-p") == 0) {
      print_flag = 1;
      argc--;
   }

   if (argc > 2) {
      start = (uint64_t) strtold(argv[1], NULL);
      stop  = (uint64_t) strtold(argv[2], NULL);
   }
   else if (argc > 1) {
      stop  = (uint64_t) strtold(argv[1], NULL);
   }

   if (stop > 0 && stop >= start) {
      if (stop - start > 1e+11) {
         fprintf(stderr, "Range distance exceeds 1e+11 (~4GB).\n");
         return 1;
      }
      double tstart = omp_get_wtime();
      prangesieve(start, stop, print_flag);
      double tend = omp_get_wtime();
      fprintf(stderr, "Seconds: %0.3lf\n", tend - tstart);
   }

   return 0;
}

