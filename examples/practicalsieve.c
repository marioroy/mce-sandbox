
// Algorithm3 (non-segmented variant).
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
//   gcc -o practicalsieve -I../src -O3 practicalsieve.c -lm
//   gcc -o practicalsieve -I../src -O3 -march=x86-64-v3 practicalsieve.c -lm
//
// Usage:
//   practicalsieve [ N ]   default 1000
//   practicalsieve 1e+10

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include "bits.h"

void practicalsieve(uint64_t stop)
{
   int64_t q = (int64_t) sqrt((double) stop) / 3;
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

   for (i = 1; i <= q; i++) {
      k = 3 - k, c += 4 * k * i, j = c;
      ij = 2 * i * (3 - k) + 1, t += 4 * k;
      if (GETBIT(sieve, i)) {
         // clear composites
         while (j <= M) {
            CLRBIT(sieve, j);
            j += ij, ij = t - ij;
         }
      }
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

   if (limit > 1e+11) {
      fprintf(stderr, "Limit exceeds 1e+11 (~4GB).\n");
      return 1;
   }

   practicalsieve(limit);

   return 0;
}

