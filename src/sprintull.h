#line 2 "../src/sprintull.h"
//#############################################################################
// ----------------------------------------------------------------------------
// C helper function for fast base10 to string conversion.
//
//#############################################################################

#ifndef SPRINTULL_H
#define SPRINTULL_H

#include <stdint.h>

const int N_MAXDIGITS = (sizeof(uint64_t) * 8 * sizeof(char) / 3) + 2;

// This works similarly like sprintf, particularly returning the number of
// characters.

int sprintull(char *endptr, uint64_t value)
{
   int n_chars; uint64_t t; char *s = endptr, c;

   // base10 to string conversion
   do {
      t = value / 10; *s++ = (char) ('0' + value - 10 * t);
   } while ((value = t));

   // save # of characters excluding the null character
   n_chars = s - endptr;  *s = '\0';

   // reverse the string in place
   while (--s > endptr)
      c = *s, *s = *endptr, *endptr++ = c;

   return n_chars;
}

#endif

