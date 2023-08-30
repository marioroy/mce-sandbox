#line 2 "../src/bits.h"
//#############################################################################
// ----------------------------------------------------------------------------
// C helper functions.
//
//#############################################################################

#ifndef BITS_H
#define BITS_H

#include <stdint.h>

typedef unsigned char byte_t;

static const byte_t popcnt_byte[256] = {
   0,1,1,2,1,2,2,3,1,2,2,3,2,3,3,4,1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,
   1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,
   1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,
   2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
   1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,
   2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
   2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
   3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,4,5,5,6,5,6,6,7,5,6,6,7,6,7,7,8
};

static const int unset_bit[8] = {
   (~(1 << 0) & 0xff), (~(1 << 1) & 0xff),
   (~(1 << 2) & 0xff), (~(1 << 3) & 0xff),
   (~(1 << 4) & 0xff), (~(1 << 5) & 0xff),
   (~(1 << 6) & 0xff), (~(1 << 7) & 0xff)
};

#define CLRBIT(s,i) s[(int64_t)(i) >> 3] &= unset_bit[(i) & 7]
#define GETBIT(s,i) s[(int64_t)(i) >> 3] &  (1 << ((i) & 7))
#define SETBIT(s,i) s[(int64_t)(i) >> 3] |= (1 << ((i) & 7))

// The popcount function is based on popcnt from Math::Prime::Util.

static int64_t popcount(const byte_t *bytearray, int64_t size)
{
   int64_t asize, i, count = 0;

   if (bytearray == 0 || size == 0)
      return count;

   if (size > 8) {
      #ifdef __LP64__
         static const uint64_t m1  = UINT64_C(0x5555555555555555);
         static const uint64_t m2  = UINT64_C(0x3333333333333333);
         static const uint64_t m4  = UINT64_C(0x0f0f0f0f0f0f0f0f);
         static const uint64_t h01 = UINT64_C(0x0101010101010101);

         const uint64_t *a = (uint64_t *) bytearray;
         uint64_t b;

         asize = (size + 7) / 8 - 1;

         for (i = 0; i < asize; i++) {
            b = a[i];
            b =  b       - ((b >> 1)  & m1);
            b = (b & m2) + ((b >> 2)  & m2);
            b = (b       +  (b >> 4)) & m4;
            count += (b * h01) >> 56;
         }

         i = asize * 8;

      #else
         static const uint32_t m1  = UINT32_C(0x55555555);
         static const uint32_t m2  = UINT32_C(0x33333333);
         static const uint32_t m4  = UINT32_C(0x0f0f0f0f);
         static const uint32_t h01 = UINT32_C(0x01010101);

         const uint32_t *a = (uint32_t *) bytearray;
         uint32_t b;

         asize = (size + 3) / 4 - 1;

         for (i = 0; i < asize; i++) {
            b = a[i];
            b =  b       - ((b >> 1)  & m1);
            b = (b & m2) + ((b >> 2)  & m2);
            b = (b       +  (b >> 4)) & m4;
            count += (b * h01) >> 24;
         }

         i = asize * 4;

      #endif
   }
   else
      i = 0;

   for (; i < size; i++)
      count += popcnt_byte[bytearray[i]];

   return count;
}

#endif

