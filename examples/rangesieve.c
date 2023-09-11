
// Algorithm3 (range variant).
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
//   gcc -o rangesieve -I../src -O3 rangesieve.c -lm
//   gcc -o rangesieve -I../src -O3 -march=x86-64-v3 rangesieve.c -lm
//
// Usage:
//   rangesieve [ N [ N ] [ -p ] ]  default 1 1000
//   rangesieve 100 -p              print primes found
//   rangesieve 1e+10 1.1e+10       count primes found
//   rangesieve 87233720365000000 87233720368547757
//   rangesieve 18446744073000000000 18446744073709551609
//   rangesieve 1e12 1.1e12

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include "bits.h"

static const int SEGMENT_SIZE = 510510 * 12;

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

void rangesieve(uint64_t start, uint64_t stop, int print_flag)
{
   byte_t *is_prime = makeprimes(stop);
   int64_t count = 0;

   // adjust start to a multiple of 6; then subtract 6 and add 1
   uint64_t start_adj = (start > 5)
      ? start - (start % 6) - 6 + 1
      : 1;

   int64_t M = (stop - start_adj + (stop & 1)) / 3;
   int64_t i, c = 0, k = 1, t = 2, j, ij;
   uint64_t n_off = start_adj - 1;
   int64_t j_off = n_off / 3;
   int64_t mem_sz = (M + 2 + 7) / 8;
   byte_t  *sieve;

   sieve = (byte_t *) malloc(mem_sz);
   memset(sieve, 0xff, mem_sz);
   CLRBIT(sieve, 0);

   // clear bits less than start
   if (n_off + ((3 * 1 + 1) | 1) < start) {
      CLRBIT(sieve, 1);
      if (n_off + ((3 * 2 + 1) | 1) < start)
         CLRBIT(sieve, 2);
   }

   // clear bits greater than stop
   i = mem_sz * 8 - (M + 2);
   while (i) {
      CLRBIT(sieve, mem_sz * 8 - i);
      i--;
   }
   if (n_off + ((3 * (M + 1) + 1) | 1) > stop) {
      CLRBIT(sieve, M + 1);
      if (n_off + ((3 * M + 1) | 1) > stop)
         CLRBIT(sieve, M);
   }

   //=========================================================================
   // segmented loop
   //=========================================================================
   if (stop < 1e15) {
      int64_t num_segments = (stop - start_adj + SEGMENT_SIZE) / SEGMENT_SIZE;
      int64_t cc = c, kk = k, tt = t, j_off2 = j_off;

      for (int64_t n = 0; n < num_segments; n++) {
         uint64_t low = start_adj + (SEGMENT_SIZE * n);
         uint64_t high = low + SEGMENT_SIZE - 1;

         // check also high < low in case addition overflowed
         if (high > stop || high < low) high = stop;

         int64_t q = (int64_t) sqrt((double) high) / 3;
         int64_t m = high / 3;

         c = cc, k = kk, t = tt;
         for (i = 1; i <= q; i++) {
            k = 3 - k, c += 4 * k * i, j = c;
            ij = 2 * i * (3 - k) + 1, t += 4 * k;
            if (GETBIT(is_prime, i)) {
               // skip numbers before this segment
               if (j < j_off2) {
                  j += (j_off2 - j) / t * t + ij;
                  ij = t - ij;
                  if (j < j_off2)
                     j += ij, ij = t - ij;
               }
               // clear composites
               while (j <= m) {
                  CLRBIT(sieve, j - j_off);
                  j += ij, ij = t - ij;
               }
            }
         }

         j_off2 = m;
      }
   }

   //=========================================================================
   // non-segmented loop
   //=========================================================================
   else {
      int64_t q = (int64_t) sqrt((double) stop) / 3;
      int64_t m = stop / 3;

      for (i = 1; i <= q; i++) {
         k = 3 - k, c += 4 * k * i, j = c;
         ij = 2 * i * (3 - k) + 1, t += 4 * k;
         if (GETBIT(is_prime, i)) {
            // skip numbers before this segment
            if (j < j_off) {
               j += (j_off - j) / t * t + ij;
               ij = t - ij;
               if (j < j_off)
                  j += ij, ij = t - ij;
            }
            // clear composites
            while (j <= m) {
               CLRBIT(sieve, j - j_off);
               j += ij, ij = t - ij;
            }
         }
      }
   }

   free((void *) is_prime);
   is_prime = NULL;

   if (start <= 2 && stop >= 2) count++;
   if (start <= 3 && stop >= 3) count++;

   count += popcount(sieve, mem_sz);

   if (print_flag) {
      if (start <= 2 && stop >= 2) printf("2\n");
      if (start <= 3 && stop >= 3) printf("3\n");
      for (i = 1; i <= M; i += 2) {
         if (GETBIT(sieve, i))
            printf("%lu\n", n_off + (3 * i + 2));
         if (GETBIT(sieve, i + 1))
            printf("%lu\n", n_off + (3 * (i + 1) + 1));
      }
   }

   free((void *) sieve);
   sieve = NULL;

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
      rangesieve(start, stop, print_flag);
   }

   return 0;
}

