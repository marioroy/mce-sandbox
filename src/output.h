#line 2 "../src/output.h"
//#############################################################################
// ----------------------------------------------------------------------------
// C helper functions for fast printing of primes.
//
//#############################################################################

#ifndef OUTPUT_H
#define OUTPUT_H

#include <stdint.h>
#include <stdio.h>

#include "sprintull.h"

const int FLUSH_LIMIT = 393000;     // = 384K - 216

int flush_output(int fd, char *endptr, int *lenptr)
{
   if (*lenptr > 0) {
      uint32_t written;

      if ((written = write(fd, endptr, *lenptr)) != *lenptr) {
         fprintf(stderr, "Could not write to output stream\n");
         *lenptr = 0; return -1;
      }

      *lenptr = 0;
   }

   return 0;
}

int write_output(int fd, char *endptr, uint64_t prime, int *lenptr)
{
   *lenptr += sprintull(endptr + *lenptr, prime);
   *( endptr + (*lenptr)++ ) = '\n';

   if (*lenptr > FLUSH_LIMIT)
      return flush_output(fd, endptr, lenptr);

   return 0;
}

#endif

