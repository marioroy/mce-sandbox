
// Algorithm3 (segmented variant).
//   C demonstration by Mario Roy, 2023-08-31
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
//   gcc -o segmentsieve -I../src -O3 segmentsieve.c -lm
//   gcc -o segmentsieve -I../src -O3 -march=x86-64-v3 segmentsieve.c -lm
//
// Usage:
//   segmentsieve [ N ]   default 1000
//   segmentsieve 1e+10

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include "bits.h"

static const int SEGMENT_SIZE = 510510 * 12;

void segmentsieve(uint64_t stop)
{
   int64_t M = stop / 3;
   int64_t i, c = 0, k = 1, t = 2, j, ij;
   int64_t mem_sz = (M + 2 + 7) / 8;
   byte_t  *sieve;

   sieve = (byte_t *) malloc(mem_sz);
   memset(sieve, 0xff, mem_sz);
   CLRBIT(sieve, 0);

   // clear bits greater than stop
   i = mem_sz * 8 - (M + 2);
   while (i) {
      CLRBIT(sieve, mem_sz * 8 - i);
      i--;
   }
   if (((3 * (M + 1) + 1) | 1) > stop) {
      CLRBIT(sieve, M + 1);
      if (((3 * M + 1) | 1) > stop)
         CLRBIT(sieve, M);
   }

   int64_t num_segments = (stop - 1 + SEGMENT_SIZE) / SEGMENT_SIZE;
   int64_t cc = c, kk = k, tt = t, j_off = 0;

   for (int64_t n = 0; n < num_segments; n++) {
      uint64_t low = 1 + (SEGMENT_SIZE * n);
      uint64_t high = low + SEGMENT_SIZE - 1;

      // check also high < low in case addition overflowed
      if (high > stop || high < low) high = stop;

      int64_t q = (int64_t) sqrt((double) high) / 3;
      int64_t m = high / 3;

      c = cc, k = kk, t = tt;

      for (i = 1; i <= q; i++) {
         k  = 3 - k, c += 4 * k * i, j = c;
         ij = 2 * i * (3 - k) + 1, t += 4 * k;
         if (GETBIT(sieve, i)) {
            // skip numbers before this segment
            if (j < j_off) {
               j += (j_off - j) / t * t + ij;
               ij = t - ij;
               if (j < j_off)
                  j += ij, ij = t - ij;
            }
            // clear composites
            while (j <= m) {
               CLRBIT(sieve, j);
               j += ij, ij = t - ij;
            }
         }
      }

      j_off = m;
   }

   int64_t count = (stop < 2) ? 0 : (stop < 3) ? 1 : 2;

   count += popcount(sieve, mem_sz);

   // if (stop >= 2) printf("2\n");
   // if (stop >= 3) printf("3\n");
   // for (i = 1; i <= M; i += 2) {
   //    if (GETBIT(sieve, i))
   //       printf("%lu\n", 3 * i + 2);
   //    if (GETBIT(sieve, i + 1))
   //       printf("%lu\n", 3 * (i + 1) + 1);
   // }

   free((void *) sieve);
   sieve = NULL;

   fprintf(stderr, "Primes found: %ld\n", count);
}

int main(int argc, char** argv)
{
   // count the primes below this number
   uint64_t limit = 1000;

   if (argc >= 2) {
      limit = (uint64_t) strtold(argv[1], NULL);
   }

   if (limit > 5e+10) {
      fprintf(stderr, "Limit exceeds 5e+10 (~2GB).\n");
      return 1;
   }

   segmentsieve(limit);

   return 0;
}

