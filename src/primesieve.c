#line 2 "../src/primesieve.c"
//#############################################################################
// ----------------------------------------------------------------------------
// C source to count, sum, or generate prime numbers in order.
//
//#############################################################################

#include <primesieve.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "sandbox.h"

//#############################################################################
// ----------------------------------------------------------------------------
// Sieve function.
//
//#############################################################################

SV* primesieve(SV *start_sv, SV *limit_sv, int run_mode, int fd)
{
   AV       *ret;
   uint64_t n_ret, start, limit, *primes;
   size_t   size, i;
   int      err;

   #ifdef __LP64__
      start = SvUV(start_sv);
      limit = SvUV(limit_sv);
   #else
      start = strtoull(SvPV_nolen(start_sv), NULL, 10);
      limit = strtoull(SvPV_nolen(limit_sv), NULL, 10);
   #endif

   ret = newAV(), n_ret = 0, err = 0;

   //====================================================================
   // Count primes, sum primes, otherwise output primes for this block.
   //====================================================================

   if (run_mode == MODE_COUNT) {
      n_ret = primesieve_count_primes(start, limit);
   }
   else {
      primes = primesieve_generate_primes(start, limit, &size, UINT64_PRIMES);

      if (run_mode == MODE_SUM) {
         for (i = 0; i < size; i++)
            n_ret += primes[i];
      }
      else {
         char *buf; int len;

         buf = (char *) malloc(sizeof(char) * (FLUSH_LIMIT + 216));
         len = 0;

         for (i = 0; i < size; i++) {
            if ((err = write_output(fd, buf, primes[i], &len)))
               break;
         }

         if (!err)
            err = flush_output(fd, buf, &len);

         free((void *) buf);
         buf = NULL;
      }

      primesieve_free(primes);
   }

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

