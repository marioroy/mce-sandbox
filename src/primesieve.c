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

void primesieve_disable_threading()
{
   primesieve_set_num_threads(1);
}

SV* primesieve(SV *start_sv, SV *stop_sv, int run_mode, int fd)
{
   AV       *ret;
   uint64_t n_ret, start, stop;
   int      err;

   #ifdef __LP64__
      start = SvUV(start_sv);
      stop  = SvUV(stop_sv);
   #else
      start = strtoull(SvPV_nolen(start_sv), NULL, 10);
      stop  = strtoull(SvPV_nolen(stop_sv), NULL, 10);
   #endif

   ret = newAV(), n_ret = 0UL, err = 0;

   //====================================================================
   // Count, sum, otherwise output primes for this segment.
   //====================================================================

   if (run_mode == MODE_COUNT) {
      n_ret += primesieve_count_primes(start, stop);
   }
   else {
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
      if (start <= 18446744073709551557UL && stop >= 18446744073709551557UL)
         include_last_prime = 18446744073709551557UL;
      else
         include_last_prime = 0UL;

      if (start > 18446744073709551556UL) start = 18446744073709551556UL;
      if (stop  > 18446744073709551556UL) stop  = 18446744073709551556UL;

      primesieve_iterator it;
      primesieve_init(&it);
      primesieve_jump_to(&it, start, stop);

      if (run_mode == MODE_SUM) {
         uint64_t prime = primesieve_next_prime(&it);
         for (; prime <= stop; prime = primesieve_next_prime(&it))
            n_ret += prime;
         // this application supports --sum up to 29,505,444,490 limit
         // tally the last unsigned 64-bit prime is not needed here
      }
      else {
         char *buf = (char *) malloc(sizeof(char) * (FLUSH_LIMIT + 216));
         int len = 0;

         uint64_t prime = primesieve_next_prime(&it);
         for (; prime <= stop; prime = primesieve_next_prime(&it)) {
            if ((err = write_output(fd, buf, prime, &len)))
               break;
         }
         if (!err && include_last_prime)
            err = write_output(fd, buf, include_last_prime, &len);
         if (!err)
            err = flush_output(fd, buf, &len);

         free((void *) buf);
         buf = NULL;
      }
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

