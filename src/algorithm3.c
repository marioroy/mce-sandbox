#line 2 "../src/algorithm3.c"
//#############################################################################
// ----------------------------------------------------------------------------
// C source to count, sum, or generate prime numbers in order.
//
//#############################################################################

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#include "sandbox.h"

static uint64_t FROM_val, FROM_adj, N_val;
static byte_t   *is_prime, *pre_sieve;

//#############################################################################
// ----------------------------------------------------------------------------
// Practical sieve (precalc) and (memfree) functions.
//
//#############################################################################

void practicalsieve_precalc(
      SV *from_adj_sv, SV *from_val_sv, SV *n_val_sv, SV *step_sz_sv )
{
   int64_t j_off, c, k, t, j, ij, step_sz, sieve_sz;
   int64_t c_off, i, q, mem_sz;

   #ifdef __LP64__
      FROM_adj = SvUV(from_adj_sv);
      FROM_val = SvUV(from_val_sv);
      N_val    = SvUV(n_val_sv);
      step_sz  = SvUV(step_sz_sv);
   #else
      FROM_adj = strtoull(SvPV_nolen(from_adj_sv), NULL, 10);
      FROM_val = strtoull(SvPV_nolen(from_val_sv), NULL, 10);
      N_val    = strtoull(SvPV_nolen(n_val_sv), NULL, 10);
      step_sz  = strtoull(SvPV_nolen(step_sz_sv), NULL, 10);
   #endif

   if (N_val < 1e12) {
      if (step_sz % 510510 != 0) {
         // A multiple of 510510 is required for the pre-sieve logic.
         fprintf(stderr, "error: step_size is not a multiple of 510510\n");
         exit(2);
      }
   } else {
      if (step_sz % 9699690 != 0) {
         // A multiple of 9699690 is required for the pre-sieve logic.
         fprintf(stderr, "error: step_size is not a multiple of 9699690\n");
         exit(2);
      }
   }

   //====================================================================
   // Compute is_prime. This enables workers to process faster.
   //====================================================================

   q = (int64_t) sqrt((double) N_val) / 3;
   c = 0, k = 1, t = 2;

   mem_sz = (q + 2 + 7) / 8;
   is_prime = (byte_t *) malloc(mem_sz);
   if (is_prime == NULL) {
      fprintf(stderr, "error: failed to allocate is_prime memory.\n");
      exit(2);
   }
   memset(is_prime, 0xff, mem_sz);
   CLRBIT(is_prime, 0);

   // clear small composites <= q
   for (i = 1; i <= q; i++) {
      k = 3 - k, c += 4 * k * i, j = c;
      ij = 2 * i * (3 - k) + 1, t += 4 * k;
      if (GETBIT(is_prime, i)) {
         while (j <= q) {
            CLRBIT(is_prime, j);
            j += ij, ij = t - ij;
         }
      }
   }

   //====================================================================
   // if N < 1e12
   //    Pre-sieve 5, 7, 11, 13, and 17 (i = 1 through 5).
   // else
   //    Pre-sieve 5, 7, 11, 13, 17, and 19 (i = 1 through 6).
   //====================================================================

   sieve_sz = step_sz / 3;
   mem_sz = (sieve_sz + 2 + 7) / 8;
   pre_sieve = (byte_t *) malloc(mem_sz);
   if (pre_sieve == NULL) {
      free((void *) is_prime);
      fprintf(stderr, "error: failed to allocate pre_sieve memory.\n");
      exit(2);
   }
   memset(pre_sieve, 0xff, mem_sz);
   CLRBIT(pre_sieve, 0);

   j_off = (FROM_adj - 1) / 3;
   c = 0, k = 1, t = 2;

   for (i = 1; i <= (N_val < 1e12 ? 5 : 6); i++) {
      k = 3 - k, c += 4 * k * i, j = c;
      ij = 2 * i * (3 - k) + 1, t += 4 * k;

      // skip numbers before FROM_adj
      if (j < j_off) {
         j += (j_off - j) / t * t + ij;
         ij = t - ij;
         if (j < j_off)
            j += ij, ij = t - ij;
      }
      // clear composites (j <= sieve_sz)
      c_off = j - j_off;
      while ((c_off >> 3) < mem_sz) {
         CLRBIT(pre_sieve, c_off);
         j += ij, ij = t - ij;
         c_off = j - j_off;
      }
   }

   //====================================================================
   // if N < 1e12
   // ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   // 1. At this point, i = 6, c = 96, k = 2, and t = 34.
   //    Workers will not need to process i = 1 through 5.
   // 2. Clear bits for 5, 7, 11, 13, and 17 including bit 0.
   //    The worker processing the first chunk will undo this.
   // else
   // ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   // 1. At this point, i = 7, c = 120, k = 1, and t = 38.
   //    Workers will not need to process i = 1 through 6.
   // 2. Clear bits for 5, 7, 11, 13, 17, and 19 including bit 0.
   //    The worker processing the first chunk will undo this.
   //====================================================================

   if (FROM_adj == 1) {
      pre_sieve[0] = (N_val < 1e12) ? 0xc0 : 0x80;
   }

   // clear bits greater than "sieve_sz"
   i = mem_sz * 8 - (sieve_sz + 1);
   while (i) {
      CLRBIT(pre_sieve, mem_sz * 8 - i);
      i--;
   }
}

void practicalsieve_memfree()
{
   free((void *) pre_sieve);
   pre_sieve = NULL;
   free((void *) is_prime);
   is_prime = NULL;

   fflush(stdout);
}

//#############################################################################
// ----------------------------------------------------------------------------
// Parallel sieve based off serial code from Xuedong Luo (Algorithm3).
//
// <> A practical sieve algorithm for finding prime numbers.
//    ACM Volume 32 Issue 3, March 1989, Pages 344-346
//    https://dl.acm.org/doi/pdf/10.1145/62065.62072
//    https://dl.acm.org/citation.cfm?doid=62065.62072
//
//#############################################################################

SV* practicalsieve(SV *start_sv, SV *stop_sv, int run_mode, int fd)
{
   AV       *ret;
   uint64_t start, stop, n_off;
   int64_t  n_ret, j_off, c, k, t, j, ij;
   int64_t  q, M, M2, i, mem_sz;
   byte_t   *sieve;
   int      err;

   #ifdef __LP64__
      start = SvUV(start_sv);
      stop  = SvUV(stop_sv);
   #else
      start = strtoull(SvPV_nolen(start_sv), NULL, 10);
      stop  = strtoull(SvPV_nolen(stop_sv), NULL, 10);
   #endif

   ret = newAV(), n_ret = 0, err = 0;

   //====================================================================
   // Sieve algorithm.
   //====================================================================

   q = (int64_t) sqrt((double) stop) / 3;
   M = (stop - start + (stop & 1)) / 3;
   M2 = stop / 3;
   n_off = start - 1, j_off = n_off / 3;
   mem_sz = (M + 2 + 7) / 8;

   sieve = (byte_t *) malloc(mem_sz);

   // copy pre-sieved data into sieve
   // fix byte 0 if starting at 1 (has primes 5,7,11,13,17,19,23)
   memcpy(sieve, pre_sieve, mem_sz);
   if (start == 1) sieve[0] = 0xfe;

   // clear composites less than "FROM_val"
   if (start == FROM_adj && n_off + ((3 * 1 + 1) | 1) < FROM_val) {
      CLRBIT(sieve, 1);
      if (n_off + ((3 * 2 + 1) | 1) < FROM_val)
         CLRBIT(sieve, 2);
   }

   // clear composites greater than "N_val"
   if (stop == N_val) {
      i = mem_sz * 8 - (M + 2);
      while (i) {
         CLRBIT(sieve, mem_sz * 8 - i);
         i--;
      }
      if (n_off + ((3 * (M + 1) + 1) | 1) > N_val) {
         CLRBIT(sieve, M + 1);
         if (n_off + ((3 * M + 1) | 1) > N_val)
            CLRBIT(sieve, M);
      }
   }

   if (N_val < 1e12) {
   // sieving begins with 19 (i = 6)
      c = 96, k = 2, t = 34;
   } else {
   // sieving begins with 23 (i = 7)
      c = 120, k = 1, t = 38;
   }

   for (i = (N_val < 1e12 ? 6 : 7); i <= q; i++) {
      k = 3 - k, c += 4 * k * i, j = c;
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

   //====================================================================
   // Count primes, sum primes, otherwise output primes for this block.
   //====================================================================

   if (run_mode == MODE_COUNT) {
      if (FROM_val <= 2 && start <= 2 && stop >= 2) n_ret++;
      if (FROM_val <= 3 && start <= 3 && stop >= 3) n_ret++;

      n_ret += popcount(sieve, mem_sz);
   }
   else if (run_mode == MODE_SUM) {
      if (FROM_val <= 2 && start <= 2 && stop >= 2) n_ret += 2;
      if (FROM_val <= 3 && start <= 3 && stop >= 3) n_ret += 3;

      for (i = 1; i <= M; i += 2) {
         if (GETBIT(sieve, i))
            n_ret += n_off + (3 * i + 2);
         if (GETBIT(sieve, i + 1))
            n_ret += n_off + (3 * (i + 1) + 1);
      }
   }
   else {
      char *buf; int len;

      buf = (char *) malloc(FLUSH_LIMIT + 216);
      len = 0;

      // Think of an imaginary list containing sequence of numbers.
      // The n_off value is the starting offset into this list.
      //
      // Avoid all composites that have 2 or 3 as one of their prime
      // factors (where i is odd). Index 0 is not used.
      //
      // { 0, 5, 7, 11, 13, ... 3i + 2, 3(i + 1) + 1, ..., N }
      //   0, 1, 2,  3,  4, ... list indices (0 is not used)

      if (FROM_val <= 2 && start <= 2 && stop >= 2)
         write_output(fd, buf, 2, &len);
      if (FROM_val <= 3 && start <= 3 && stop >= 3)
         write_output(fd, buf, 3, &len);

      for (i = 1; i <= M; i += 2) {
         if (GETBIT(sieve, i))
            if ((err = write_output(fd, buf, n_off + (3*i+2), &len)))
               break;
         if (GETBIT(sieve, i + 1))
            if ((err = write_output(fd, buf, n_off + (3*(i+1)+1), &len)))
               break;
      }

      if (!err)
         err = flush_output(fd, buf, &len);

      free((void *) buf);
      buf = NULL;
   }

   free((void *) sieve);
   sieve = NULL;

   //====================================================================
   // Return.
   //====================================================================

   if (run_mode == MODE_PRINT) {
      av_push(ret, newSViv(err));
   }
   else {
      #ifdef __LP64__
         av_push(ret, newSVuv(n_ret));
      #else
         SV *n_sv; char *ptr; STRLEN len; int n_chars;
         n_sv = newSVpvn("", N_MAXDIGITS);
         ptr = SvPV(n_sv, len);
         n_chars = sprintull(ptr, n_ret);
         av_push(ret, newSVpvn(ptr, n_chars));
      #endif
   }

   return newRV_noinc((SV *) ret);
}

