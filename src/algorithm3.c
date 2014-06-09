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

const  int64_t  QP_LIMIT = 1054092553;   // sqrt(1e19)/3

static uint64_t FROM_val, FROM_adj, N_val;
static byte_t   *is_prime, *pre_sieve17;

//#############################################################################
// ----------------------------------------------------------------------------
// Sieve init and finish functions.
//
//#############################################################################

void practicalsieve_init(
      SV *from_val_sv, SV *from_adj_sv, SV *n_val_sv, SV *sieve_sz_sv )
{
   uint64_t j_off, c, k, t, j, ij, sieve_sz;
   int64_t  c_off, i, q, mem_sz;

   #ifdef __LP64__
      FROM_val = SvUV(from_val_sv);
      FROM_adj = SvUV(from_adj_sv);
      N_val    = SvUV(n_val_sv);
      sieve_sz = SvUV(sieve_sz_sv);
   #else
      FROM_val = strtoull(SvPV_nolen(from_val_sv), NULL, 10);
      FROM_adj = strtoull(SvPV_nolen(from_adj_sv), NULL, 10);
      N_val    = strtoull(SvPV_nolen(n_val_sv), NULL, 10);
      sieve_sz = strtoull(SvPV_nolen(sieve_sz_sv), NULL, 10);
   #endif

   //====================================================================
   // Compute is_prime. This enables workers to process faster.
   //====================================================================

   q = (int64_t) sqrt((double) N_val) / 3;
   c = 0, k = 1, t = 2;

   if (q > QP_LIMIT) q = QP_LIMIT;

   mem_sz = (q + 2 + 7) / 8;
   is_prime = (byte_t *) malloc(mem_sz);
   memset(is_prime, 0xff, mem_sz);

   // Clear small composites <= q. Workers to clear <= M.
   for (i = 1; i <= q; i++) {
      k  = 3 - k, c = 4 * k * i + c, j = c;
      ij = 2 * i * (3 - k) + 1, t = 4 * k + t;

      if (ISBITSET(is_prime, i)) {
         while (j <= q) {
            CLEARBIT(is_prime, j);
            j += ij, ij = t - ij;
         }
      }
   }

   //====================================================================
   // Pre-sieve 5, 7, 11, 13, and 17 (i = 1 through 5).
   //====================================================================

   sieve_sz /= 3, mem_sz = (sieve_sz + 2 + 7) / 8;

   pre_sieve17 = (byte_t *) malloc(mem_sz);
   memset(pre_sieve17, 0xff, mem_sz);
   CLEARBIT(pre_sieve17, 0);

   j_off = (FROM_adj - 1) / 3;
   c = 0, k = 1, t = 2;

   for (i = 1; i <= 5; i++) {
      k  = 3 - k, c = 4 * k * i + c, j = c;
      ij = 2 * i * (3 - k) + 1, t = 4 * k + t;

      // Skip numbers before FROM_adj.
      if (j < j_off) {
         j += (j_off - j) / t * t + ij, ij = t - ij;
         if (j < j_off)
            j += ij, ij = t - ij;
      }

      // Clear composites.
      c_off = (int64_t) j - j_off;

      while ((c_off >> 3) < mem_sz) {
         CLEARBIT(pre_sieve17, c_off);
         j += ij, ij = t - ij;
         c_off = (int64_t) j - j_off;
      }
   }

   //====================================================================
   // At this point, i = 6, c = 96, k = 2, and t = 34.
   // Workers will not need to process i = 1 through 5.
   //====================================================================

   // Clear bits for 5,7,11,13,17 including bit 0.
   // A worker will undo this only when starting at 1.
   if (FROM_adj == 1) pre_sieve17[0] = 0xc0;
}

void practicalsieve_finish()
{
   free((void *) pre_sieve17);
   pre_sieve17 = NULL;

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
//    http://dl.acm.org/citation.cfm?doid=62065.62072
//
//#############################################################################

SV* practicalsieve(SV *start_sv, SV *limit_sv, int run_mode, int fd)
{
   AV       *ret;
   uint64_t n_ret, start, limit, j_off, n_off, M, c, k, t, j, ij;
   int64_t  q, size, i, mem_sz;
   byte_t   *sieve;
   int      err, flag;

   #ifdef __LP64__
      start = SvUV(start_sv);
      limit = SvUV(limit_sv);
   #else
      start = strtoull(SvPV_nolen(start_sv), NULL, 10);
      limit = strtoull(SvPV_nolen(limit_sv), NULL, 10);
   #endif

   ret = newAV(), n_ret = 0, err = 0;

   //====================================================================
   // Sieve algorithm.
   //====================================================================

   M = limit / 3, c = 96, k = 2, t = 34, q = sqrt(limit) / 3;
   size = (limit + (limit & 1) - start) / 3;
   n_off = start - 1, j_off = n_off / 3;
   mem_sz = (size + 2 + 7) / 8;

   sieve = (byte_t *) malloc(mem_sz);

   // Copy pre-sieved data into sieve.
   memcpy(sieve, pre_sieve17, mem_sz);

   // Fix byte 0 if starting at 1 (has primes 5,7,11,13,17).
   if (start == 1) sieve[0] = 0xfe;

   // Unset bits > limit.
   i = mem_sz * 8 - (size + 2);

   while (i) {
      CLEARBIT(sieve, (mem_sz - 1) * 8 + (8 - i));
      i--;
   }

   // Clear composites < FROM_val.
   if (start == FROM_adj) {
      for (i = 1; i <= 3; i++) {
         if (n_off + (3 * i + 1 | 1) >= FROM_val)
            break;
         CLEARBIT(sieve, i);
      }
   }

   // Clear composites > N_val.
   if (limit == N_val) {
      if (n_off + (3 * (size + 1) + 1) > N_val + (N_val & 1))
         CLEARBIT(sieve, size + 1);
      if (n_off + (3 * size + 2) > N_val + (N_val & 1))
         CLEARBIT(sieve, size);
   }

   // Process this block. Sieving begins with 19 (i = 6).
   for (i = 6; i <= q; i++) {
      k  = 3 - k, c = 4 * k * i + c, j = c;
      ij = 2 * i * (3 - k) + 1, t = 4 * k + t;

      // The is_prime array enables workers to bypass block many times.
      if ((flag = (i > QP_LIMIT)) || ISBITSET(is_prime, i)) {

         // Skip multiples of 5.
         if (flag && (3 * i + k) % 5 == 0)
            continue;

         // Skip numbers before this block.
         if (j < j_off) {
            j += (j_off - j) / t * t + ij, ij = t - ij;
            if (j < j_off)
               j += ij, ij = t - ij;
         }

         // Clear composites.
         while (j <= M) {
            CLEARBIT(sieve, j - j_off);
            j += ij, ij = t - ij;
         }
      }
   }

   //====================================================================
   // Count primes, sum primes, otherwise output primes for this block.
   //====================================================================

   if (run_mode == MODE_COUNT) {
      if (2 >= start && 2 >= FROM_val && 2 <= N_val)
         n_ret++;
      if (3 >= start && 3 >= FROM_val && 3 <= N_val)
         n_ret++;

      n_ret += popcount(sieve, mem_sz);
   }
   else if (run_mode == MODE_SUM) {
      if (2 >= start && 2 >= FROM_val && 2 <= N_val)
         n_ret += 2;
      if (3 >= start && 3 >= FROM_val && 3 <= N_val)
         n_ret += 3;

      for (i = 1; i <= size; i += 2) {
         if (ISBITSET(sieve, i))
            n_ret += n_off + (3 * i + 2);
         if (ISBITSET(sieve, i + 1))
            n_ret += n_off + (3 * (i + 1) + 1);
      }
   }
   else {
      char *buf; int len;

      buf = (char *) malloc(FLUSH_LIMIT + 216);
      len = 0;

      // Think of an imaginary list containing sequence of numbers.
      // The n_off value is used to determine the starting offset.
      //
      // Avoid all composites that have 2 or 3 as one of their prime
      // factors (where i is odd).
      //
      // { 0, 5, 7, 11, 13, ... 3i + 2, 3(i + 1) + 1, ..., N }
      //   0, 1, 2,  3,  4, ... list indices (0 is not used)

      if (2 >= start && 2 >= FROM_val && 2 <= N_val)
         write_output(fd, buf, 2, &len);
      if (3 >= start && 3 >= FROM_val && 3 <= N_val)
         write_output(fd, buf, 3, &len);

      for (i = 1; i <= size; i += 2) {
         if (ISBITSET(sieve, i))
            if ((err = write_output(fd, buf, n_off + (3*i+2), &len)))
               break;
         if (ISBITSET(sieve, i + 1))
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

