#!/bin/bash -x
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Ensure 'gcc' and 'codon' executables are in your path.
# Specify the full path otherwise.
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CODON="codon"
CC="gcc"

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Uncomment the items you wish to build.
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# ${CODON} build -release -o primes2 primes2.codon
# ${CODON} build -release -o primes4 primes4.codon

  ${CC} -o primes1 -O3 -fopenmp -I../src primes1.c -lm
  ${CC} -o primes3 -O3 -fopenmp primes3.c -lprimesieve -lm

