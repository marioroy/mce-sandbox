## Sandboxing with Perl + MCE + Inline::C

A journey with Perl, MCE, and Inline::C to count, sum, and generate prime numbers.

The sandbox has the minimum required to run the practical sieve demonstration.
Perl MCE and Inline::C modules are pre-installed under the lib directory.
ExtUtils::MakeMaker and Time::HiRes, possibly missing in Perl 8 and 10,
are required on the system.

### Content

    .Inline/           Where Inline::C is configured to cache C object files.

    bin/
       algorithm3.pl  Practical sieve based on Algorithm3 from Xuedong Luo [1].
       primesieve.pl  Calls the primesieve.org C API for generating primes.
       primeutil.pl   Utilizes the Math::Prime::Util module for primes.

    examples/
       primes1.c      Algorithm3 in C with OpenMP directives.
       primes2.codon  Algorithm3 in Codon, a Python-like language.
       primes3.c      Using libprimesieve C API in C
       primes4.codon  Using libprimesieve C API in Codon

    lib/
       Sandbox.pm     Common code for the bin scripts.

    src/
       algorithm3.c   Inline::C code for algorithm3.pl.
       bits.h         Utility functions for byte array.
       output.h       Fast printing of primes to a file descriptor.
       primesieve.c   Inline::C code for primesieve.pl.
       sandbox.h      Header file, includes bits.h, output.h, sprintull.h.
       sprintull.h    Fast base10 to string conversion.
       typemap        Type-map file for Inline::C.

Algorithm3 is something I tried early on. It will run out of the box, granted
you have a C compiler installed. Some OS environments may need to update
ExtUtils::MakeMaker manually for Inline::C to function properly; e.g Cygwin.

There is a one time delay the first time running algorithm3 and primesieve.
The delay comes from Inline::C building the relevant C files. Note: Inline::C
will not know of subsequent edits to the header files. If necessary, remove the
`.Inline` folder manually to clear the cache.

More variants using [Math::Prime::Util](https://metacpan.org/pod/Math::Prime::Util)
and [libprimesieve](https://github.com/kimwalisch/primesieve) were created next.
They run faster than algorithm3.

The examples folder is how I learned [Codon](https://github.com/exaloop/codon),
a Python-like language that compiles to native machine code. They run with
limited usage, accepting one or two integers and `-p` options. Usage can be
found at the top of the file.

### Dependencies

The `primesieve.pl` and `primeutil.pl` examples have additional dependencies.
For example, on Ubuntu Linux:

    sudo apt install libmath-prime-util-gmp-perl libmath-prime-util-perl
    sudo apt install libprimesieve-dev

Refer to primesieve's [home page](https://github.com/kimwalisch/primesieve).
Change the base path in `primesieve.pl` (lines 187 and 188) if installing
the development files elsewhere, other than `/usr` or `/usr/local`.

The Math::Prime::Util demonstration requires also, Perl::Unsafe::Signals.
This enables workers, running a long XS function, to stop immediately
upon receiving a signal.

Using 32-bit Perl, finding prime numbers above 2^32-1 requires `bigint`.
Uncomment the line `use bigint` in the following files. Leave commented
for 64-bit Perl.

    bin/algorithm3.pl
    bin/primesieve.pl
    bin/primeutil.pl
    lib/Sandbox.pm

### Usage

The following usage is taken from `algorithm3.pl`, similar for `primesieve.pl`
and `primeutil.pl`.

The base10 to string conversion and buffered IO logic provides efficient
printing of primes. Please be careful with the --print/-p options. It can
quickly fill your disk. A suggestion is specifying a range instead.

    NAME
       algorithm3.pl -- count, sum, or generate prime numbers in order

    SYNOPISIS
       algorithm3.pl [options] [[ FROM ] NUMBER ]

    DESCRIPTION
       The algorithm3.pl utility is a parallel sieve generator based off the
       3rd sieve extension from Xuedong Luo (Algorithm3) [1].

       It generates 50,847,534 primes in little time. Notice the file size for
       primes.out. This will obviously consume lots of space; e.g. running with
       1e+11 requires 45.5 GB. The upper limit for number is 2^64-1-6.

       algorithm3.pl 1e9 --print > primes.out   # file size 479 MB

       algorithm3.pl 4294967296                 # default, count primes
       203280221

       algorithm3.pl 4294967296 --sum           # sum primes otherwise
       425649736193687430

       The following options are available:

       --maxworkers=<val>   specify the number of workers (default 100%)
       --threads=<val>      alias for --maxworkers
       --usethreads         spawn workers via threads if available (not fork)
       --help,  -h          display this help and exit
       --print, -p          print primes (ignored if sum is specified)
       --quiet, -q          suppress progress including extra output
       --sum,   -s          sum primes (maximum N allowed 29505444490)

    EXAMPLES
       algorithm3.pl 18446744073000000000 18446744073709551609
       algorithm3.pl --maxworkers=8 1000000000
       algorithm3.pl --threads=50% 1e+16 1.00001e+16
       algorithm3.pl 22801763489 --sum
       algorithm3.pl 1e5 3e5 --print

    EXIT STATUS
       The algorithm3.pl utility exits with one of the following values:

       0    a prime was found
       1    a prime was not found
       >1   an error occurred

### Acknowledgements

This sandbox includes Inline::C and Parse::RecDescent. Both work reasonably
well across many environments in which MCE runs on.

The popcount function (in bits.h) is based on popcnt in Math::Prime::Util.

While making this project, I learned of a trick in POE to export variables
without having to require Exporter.

### Algorithm3 (non-segmented)

Xuedong Luo inspired me to look at Math in a new light. The example included
with mce-sandbox is the segmented version of Algorithm3.

```C
// Algorithm3 (non-segmented version) [1].
//
// Avoid all composites that have 2 or 3 as one of their prime
// factors (where i is odd).
//
// { 0, 5, 7, 11, 13, ... 3i + 2, 3(i + 1) + 1, ..., N }
//   0, 1, 2,  3,  4, ... list indices (0 is not used)

// Compiling with gcc:
//   gcc -I../src -O2 practicalsieve.c -o practicalsieve -lm

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
   CLRBIT(sieve, 0);

   // unset bits > limit;
   i = mem_sz * 8 - (M + 2);

   while (i) {
      CLRBIT(sieve, (mem_sz - 1) * 8 + (8 - i));
      i--;
   }

   if (3 * (M + 1) + 1 > limit + (limit & 1))
      CLRBIT(sieve, M + 1);
   if (3 * M + 2 > limit + (limit & 1))
      CLRBIT(sieve, M);

   for (i = 1; i <= q; i++) {
      k  = 3 - k, c = 4 * k * i + c, j = c;
      ij = 2 * i * (3 - k) + 1, t = 4 * k + t;

      if (GETBIT(sieve, i)) {
         while (j <= M) {
            CLRBIT(sieve, j);
            j += ij, ij = t - ij;
         }
      }
   }

   count += popcount(sieve, mem_sz);

   // for (i = 1; i <= M; i += 2) {
   //    if (GETBIT(sieve, i))
   //       printf("%llu\n", 3 * i + 2);
   //    if (GETBIT(sieve, i + 1))
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
   https://dl.acm.org/doi/pdf/10.1145/62065.62072
   https://dl.acm.org/citation.cfm?doid=62065.62072

