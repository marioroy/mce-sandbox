# Sandbox for Many-core Engine for Perl

This is a journey taken with Perl + MCE + Inline::C. To make this exciting,
the examples count, sum, or generate prime numbers in order.

The sandbox has the minimum required to run MCE + Inline::C. Both modules are
pre-installed under the lib directory. ExtUtils::MakeMaker and Time::HiRes,
possibly missing in Perl 8 and 10, are required on the system.

## Content

```
  .Inline/           Scripts configure Inline::C to cache C objects here

  bin/
     algorithm3.pl   Practical sieve based off Algorithm3 from Xuedong Luo [1]
     primesieve.pl   Calls the primesieve.org C API for generating primes
     primeutil.pl    Utilizes the Math::Prime::Util module for primes

  lib/
     Sandbox.pm      Common code for the bin scripts

  src/
     algorithm3.c    C code for algorithm3.pl
     bits.h          Utility functions for byte array
     output.h        Fast printing of primes to a file descriptor
     primesieve.c    C code for primesieve.pl
     sandbox.h       Header file, includes bits.h, output.h, sprintull.h
     sprintull.h     Fast base10 to string conversion
     typemap         Typemap file for Inline::C
```

There is a one time delay when running algorithm3.pl or primesieve.pl. This
is from Inline::C compiling relevant C files the very first time.

Most often, algorithm3 will run out of the box, granted you have a C compiler
installed, e.g. Xcode/gcc, MS nmake/cc, dmake/gcc, or make/gcc. Some OS
environments may need to update ExtUtils::MakeMaker for Inline::C to
function properly, e.g Cygwin.

I chose not to have many *.c files in order to have Inline::C do less checking
at startup. Simply remove the .Inline directory after making changes to any
*.h file before running.

The primesieve.pl/.c and primeutil.pl examples are complementary additions.
These have additional dependencies described below. Primesieve.c is small.
It demonstrates the generation of primes coming from an external C API.
Primeutil.pl is similar but from a Perl module instead. MCE is not used when
counting primes with Math::Prime::Util due to optimized for one core. It is
capable in counting primes many times faster than algorithm3 or primesieve.

## Dependencies

The primesieve.pl script requires the C API from primesieve.org. Change the
base path from /usr/local in primesieve.pl (lines 179,180) if installed
elsewhere.

The primeutil.pl script requires Math::Prime::Util to run. For offline
installation, acquire the necessary modules and install in the order shown.
Extract the tarball and run perl Makefile.PL. Afterwards, make/dmake/nmake
install depending on your environment.

```
  1. Math::Random::ISAAC    (Math-Random-ISAAC-1.004.tar.gz)
  2. Crypt::Random::TESHA2  (Crypt-Random-TESHA2-0.01.tar.gz)
  3. Crypt::Random::Seed    (Crypt-Random-Seed-0.03.tar.gz)
  4. Bytes::Random::Secure  (Bytes-Random-Secure-0.28.tar.gz)
  5. Math::Prime::Util      (Math-Prime-Util-0.41.tar.gz)
```

## Usage

The following usage is taken from algorithm3.pl. Both primesieve.pl and
primeutil.pl have different values for the upper limit. The usage is
similar otherwise.

The base10 to string conversion and buffered IO logic provides efficient
printing of primes. Please be careful with the --print/-p options. It can
quickly fill your disk. A suggestion is specifying both the FROM and NUMBER
arguments. A later revision will have the option to write to a PDL file.

```
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
```

## Acknowledgements

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

Xuedong Luo inspired me to look at Math in a new light. The example included
with mce-sandbox is a segmented-bit version of Algorithm3 below. My favorite
statement is "k = 3 - k". The value alternates between 1 and 2 repeatedly.

```C
  // Algorithm3 (non-segmented, sequential version) [1].
  //
  // Avoid all composites that have 2 or 3 as one of their prime
  // factors (where i is odd).
  //
  // { 0, 5, 7, 11, 13, ... 3i + 2, 3(i + 1) + 1, ..., N }
  //   0, 1, 2,  3,  4, ... list indices (0 is not used)

  #include <stdint.h>
  #include <stdlib.h>
  #include <string.h>
  #include <stdio.h>
  #include <math.h>

  void algorithm3(uint64_t limit)
  {
     int64_t i, j, q = (int64_t) sqrt((double) limit) / 3;
     uint64_t M = (uint64_t) limit / 3;
     uint64_t c = 0, k = 1, t = 2, ij;
     char *is_prime;

     is_prime = (char *) malloc(M + 2);
     memset(is_prime, 1, M + 2);

     if (3 * M + 2 > limit + (limit & 1))
        is_prime[M] = 0;
     if (3 * (M + 1) + 1 > limit + (limit & 1))
        is_prime[M + 1] = 0;

     for (i = 1; i <= q; i++) {
        k  = 3 - k, c = 4 * k * i + c, j = c;
        ij = 2 * i * (3 - k) + 1, t = 4 * k + t;

        if (is_prime[i]) {
           while (j <= M) {
              is_prime[j] = 0;
              j += ij, ij = t - ij;
           }
        }
     }

     uint64_t count = (limit < 2) ? 0 : (limit < 3) ? 1 : 2;

     for (i = 1; i <= M; i += 2) {
        if (is_prime[i]) {
        // printf("%llu\n", 3 * i + 2);
           count++;
        }
        if (is_prime[i+1]) {
        // printf("%llu\n", 3 * (i + 1) + 1);
           count++;
        }
     }

     printf("%llu primes found.\n", count);

     free((void *) is_prime);
  }

  int main(int argc, char** argv)
  {
     // count all primes below this number
     uint64_t limit = 100000000;

     if (argc >= 2)
        limit = strtoull(argv[1], NULL, 10);

     algorithm3(limit);

     return 0;
  }
```

## References

1. ** Xuedong Luo.
   A practical sieve algorithm for finding prime numbers.
   ACM Volume 32 Issue 3, March 1989, Pages 344-346
   http://dl.acm.org/citation.cfm?doid=62065.62072

