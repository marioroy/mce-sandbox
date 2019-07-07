## Sandboxing with Perl + MCE + Inline::C

This is a journey with Perl + MCE + Inline::C. To make this interesting, the
examples count, sum, and generate prime numbers.

The sandbox has the minimum required to run MCE + Inline::C. Both modules are
pre-installed under the lib directory. ExtUtils::MakeMaker and Time::HiRes,
possibly missing in Perl 8 and 10, are required on the system.

### Content

    .Inline/         Scripts configure Inline::C to cache C objects here

    bin/
      algorithm3.pl  Practical sieve based off Algorithm3 from Xuedong Luo [1]
      primesieve.pl  Calls the primesieve.org C API for generating primes
      primeutil.pl   Utilizes the Math::Prime::Util module for primes

    lib/
      Sandbox.pm     Common code for the bin scripts

    src/
      algorithm3.c   C code for algorithm3.pl
      bits.h         Utility functions for byte array
      output.h       Fast printing of primes to a file descriptor
      primesieve.c   C code for primesieve.pl
      sandbox.h      Header file, includes bits.h, output.h, sprintull.h
      sprintull.h    Fast base10 to string conversion
      typemap        Typemap file for Inline::C

There is a one time delay when running algorithm3.pl or primesieve.pl. This
is from Inline::C compiling relevant C files the very first time.

Most often, algorithm3 will run out of the box, granted you have a C compiler
installed, e.g. Xcode/gcc, MS nmake/cc, dmake/gcc, or make/gcc. Some OS
environments may need to update ExtUtils::MakeMaker for Inline::C to
function properly, e.g Cygwin.

I chose not to have many C files in order to have Inline::C do less checking
at startup. Simply remove the .Inline directory after making changes to any
header files under the src directory.

The primesieve.pl/.c and primeutil.pl examples are complementary additions.
These have additional dependencies described below. Primesieve.c is small.
It demonstrates the generation of primes coming from an external C API.
Primeutil.pl is similar but from a Perl module instead.

### Dependencies

Dependencies are available on Ubuntu Linux.

    sudo apt install libmath-prime-util-gmp-perl libmath-prime-util-perl
    sudo apt install libprimesieve-dev

On other platforms, the primesieve.pl script requires the C API from
primesieve.org. Change the base path from /usr/local in primesieve.pl
(~ lines 185,186) if installed elsewhere.

Note: Build primesieve on the Mac for both architectures.

    tar xf $HOME/Downloads/primesieve-6.1.tar.gz
    cd primesieve-6.1

    CMAKE=/Applications/CMake.app/Contents/bin/cmake
    $CMAKE "-DCMAKE_OSX_ARCHITECTURES=x86_64;i386" .

    make -j
    sudo make install

The primeutil.pl script requires Math::Prime::Util to run. For offline
installation, acquire the necessary modules and install in the order shown.
Extract the tarball and run perl Makefile.PL. Afterwards, make/dmake/nmake
install depending on your environment.

    Math::Random::ISAAC    (Math-Random-ISAAC-1.004.tar.gz)
    Crypt::Random::TESHA2  (Crypt-Random-TESHA2-0.01.tar.gz)
    Crypt::Random::Seed    (Crypt-Random-Seed-0.03.tar.gz)
    Bytes::Random::Secure  (Bytes-Random-Secure-0.28.tar.gz)
    Math::Prime::Util      (Math-Prime-Util-0.51.tar.gz)

### Note for 32-bit Perl

The scripts support 64-bit numbers. Uncomment the "use bigint" line in the
following files. This is not necessary for a NUMBER below 2^32.

    bin/algorithm3.pl
    bin/primesieve.pl
    bin/primeutil.pl
    lib/Sandbox.pm

### Usage

The following usage is taken from algorithm3.pl. Both primesieve.pl and
primeutil.pl have different values for the upper limit. The usage is
similar otherwise.

The base10 to string conversion and buffered IO logic provides efficient
printing of primes. Please be careful with the --print/-p options. It can
quickly fill your disk. A suggestion is specifying both the FROM and NUMBER
arguments. A later revision will have the option to write to a PDL file.

    NAME
       algorithm3.pl -- count, sum, or generate prime numbers in order

    SYNOPISIS
       algorithm3.pl [options] [[ FROM ] NUMBER ]

    DESCRIPTION
       The algorithm3.pl utility is a parallel sieve generator based off the
       3rd sieve extension from Xuedong Luo (Algorithm3) [1].

       It generates 50,847,534 primes in little time. Notice the file size for
       primes.out. This will obviously consume lots of space. Running with 1e11
       will require 45.5 GB. The upper limit for number is 2^64 - 1 - 6.

       algorithm3.pl 1e9 --print > primes.out   # file size 479 MB

       algorithm3.pl 4294967296                 # default, count primes
       203280221

       algorithm3.pl 4294967296 --sum           # sum primes otherwise
       425649736193687430

       The following options are available:

       --maxworkers=<val>   specify the number of workers (default auto)
       --usethreads         spawn workers via threads if available (not fork)
       --help,  -h          display this help and exit
       --print, -p          print primes (ignored if sum is specified)
       --quiet, -q          suppress progress including extra output
       --sum,   -s          sum primes (maximum N allowed 29505444490)

    EXAMPLES
       algorithm3.pl 17446744073000000000 17446744073709551609
       algorithm3.pl --maxworkers=auto/2 1000000000
       algorithm3.pl 22801763489 --sum
       algorithm3.pl 1e5 3e5 --print

    EXIT STATUS
       The algorithm3.pl utility exits with one of the following values:

       0    a prime was found
       1    a prime was not found
       >1   an error occurred

### Acknowledgements

This sandbox utilizes Inline::C and Parse::RecDescent. Both work reasonably
well among many environments in which MCE runs on. Thank you for that.

The algorithm3.c file benefitted from Dana Jacobsen's Math::Prime::Util module,
especially the idea of pre-sieving prime numbers. It led me to run algorithm3
and dump the memory contents of the sieve array after sieving for (5,7) and
afterwards (11,13,17). I was enlightened and got it.

The bits.h file, particularly the popcount function, benefited from reading
popcount.cpp at primesieve.org (Kim Walisch) including util.c in
Math::Prime::Util (Dana Jacobsen).

I remembered Rocco Caputo during this time for a trick seen long ago in POE
on exporting variables without having to require Exporter.

### Algorithm3 (non-segmented)

Xuedong Luo inspired me to look at Math in a new light. The example included
with mce-sandbox is the segmented version of Algorithm3 below. My favorite
statement is "k = 3 - k". The value alternates between 1 and 2 repeatedly.

```C
// Algorithm3 (non-segmented version) [1].
//
// Avoid all composites that have 2 or 3 as one of their prime
// factors (where i is odd).
//
// { 0, 5, 7, 11, 13, ... 3i + 2, 3(i + 1) + 1, ..., N }
//   0, 1, 2,  3,  4, ... list indices (0 is not used)

// Compiling with gcc:
//   gcc -I../src -O2 practicalsieve.c -o practicalsieve

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>

#include "bits.h"

void practicalsieve(uint64_t limit)
{
   int64_t  i, j, q = (int64_t) sqrt((double) limit) / 3;
   uint64_t M = (uint64_t) limit / 3;
   uint64_t c = 0, k = 1, t = 2, ij;
   int64_t  mem_sz = (M + 2 + 7) / 8;
   byte_t   *sieve;

   uint64_t count = (limit < 2) ? 0 : (limit < 3) ? 1 : 2;

   sieve = (byte_t *) malloc(mem_sz);
   memset(sieve, 0xff, mem_sz);
   CLEARBIT(sieve, 0);

   // unset bits > limit;
   i = mem_sz * 8 - (M + 2);

   while (i) {
      CLEARBIT(sieve, (mem_sz - 1) * 8 + (8 - i));
      i--;
   }

   if (3 * (M + 1) + 1 > limit + (limit & 1))
      CLEARBIT(sieve, M + 1);
   if (3 * M + 2 > limit + (limit & 1))
      CLEARBIT(sieve, M);

   for (i = 1; i <= q; i++) {
      k  = 3 - k, c = 4 * k * i + c, j = c;
      ij = 2 * i * (3 - k) + 1, t = 4 * k + t;

      if (ISBITSET(sieve, i)) {
         while (j <= M) {
            CLEARBIT(sieve, j);
            j += ij, ij = t - ij;
         }
      }
   }

   count += popcount(sieve, mem_sz);

   // for (i = 1; i <= M; i += 2) {
   //    if (ISBITSET(sieve, i))
   //       printf("%llu\n", 3 * i + 2);
   //    if (ISBITSET(sieve, i + 1))
   //       printf("%llu\n", 3 * (i + 1) + 1);
   // }

   free((void *) sieve);
   sieve = NULL;

   printf("%llu primes found.\n", count);
}

int main(int argc, char** argv)
{
   // count the primes below this number
   uint64_t limit = 100000000;

   if (argc >= 2)
      limit = strtoull(argv[1], NULL, 10);

   practicalsieve(limit);

   return 0;
}
```

### References

1. ** Xuedong Luo.
   A practical sieve algorithm for finding prime numbers.
   ACM Volume 32 Issue 3, March 1989, Pages 344-346
   http://dl.acm.org/citation.cfm?doid=62065.62072

