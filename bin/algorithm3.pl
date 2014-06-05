#!/usr/bin/env perl
###############################################################################
## ----------------------------------------------------------------------------
## MCE script to count, sum, and generate prime numbers in order.
##
## Author: Mario Roy, <marioeroy@gmail.com>
##
###############################################################################

use strict;
use warnings;

use Cwd qw(abs_path);

my ($prog_name, $prog_dir, $base_dir, $threads_loaded);

BEGIN {
   $prog_name = $0;             $prog_name =~ s{^.*[\\/]}{}g;
   $prog_dir  = abs_path($0);   $prog_dir  =~ s{[\\/][^\\/]*$}{};
   $base_dir  = $prog_dir;      $base_dir  =~ s{[\\/][^\\/]*$}{};

   unshift @INC, "$base_dir/lib";

   $threads_loaded = 0;

   for (@ARGV) {
      if ($_ =~ /^--use-?threads/) {
         local $@; local $SIG{__DIE__} = sub { };
         eval 'use threads; use threads::shared';
         $threads_loaded = $@ ? 0 : 1;
         last;
      }
   }
}

use bigint;

use Getopt::Long qw(:config bundling no_ignore_case no_auto_abbrev);
use Scalar::Util qw(looks_like_number);
use Time::HiRes  qw(sleep time);

use MCE::Signal  qw($tmp_dir -use_dev_shm);
use MCE;

use Sandbox;

###############################################################################
## ----------------------------------------------------------------------------
## Display usage and exit.
##
###############################################################################

sub usage()
{
   print STDERR <<"::_USAGE_BLOCK_END_::";

NAME
   $prog_name -- count, sum, or generate prime numbers in order

SYNOPISIS
   $prog_name [options] [[ FROM ] NUMBER ]

DESCRIPTION
   The $prog_name utility is a parallel sieve generator based off the
   3rd sieve extension from Xuedong Luo (Algorithm3).

        A practical sieve algorithm for finding prime numbers.
        ACM Volume 32 Issue 3, March 1989, Pages 344-346
        http://dl.acm.org/citation.cfm?doid=62065.62072

   It generates 50,847,534 primes in little time. Notice the file size for
   primes.out. This will obviously consume lots of space. Running with 1e11
   will require 45.5 GB. The upper limit for number is 2^64 - 1 - 6.

   $prog_name 1e9 --print > primes.out   # file size 479 MB

   $prog_name 4294967296                 # default, count primes
   203280221

   $prog_name 4294967296 --sum           # sum primes
   425649736193687430

   The following options are available:

   --maxworkers=<val>   specify the number of workers (default auto)
   --usethreads         spawn workers via threads if available (not fork)
   --help,  -h          display this help and exit
   --print, -p          print primes (ignored if sum is specified)
   --quiet, -q          suppress progress including extra output
   --sum,   -s          sum primes (maximum N allowed 29505444490)

EXAMPLES
   $prog_name 17446744073000000000 17446744073709551609
   $prog_name --maxworkers=auto/2 1000000000
   $prog_name 22801763489 --sum
   $prog_name 1e5 3e5 --print

EXIT STATUS
   The $prog_name utility exits with one of the following values:

   0    a prime was found
   1    a prime was not found
   >1   an error occurred

::_USAGE_BLOCK_END_::

   exit 2;
}

###############################################################################
## ----------------------------------------------------------------------------
## Define defaults. Process command-line options.
##
###############################################################################

my ($print_flag, $quiet_flag, $sum_flag, $run_mode) = (0, 0, 0, MODE_COUNT);

my $max_workers = 'auto';
my $max_number  = 18446744073709551609;   ## 2^64 - 1 - 6
my $use_threads;

{
   local $@; no warnings;

   my $help_flag = 0;

   my $result = GetOptions(
      'maxworkers|max-workers=s' => \$max_workers,
      'usethreads|use-threads'   => \$use_threads,

      'h|help'  => \$help_flag,
      'p|print' => \$print_flag,
      'q|quiet' => \$quiet_flag,
      's|sum'   => \$sum_flag
   );

   $use_threads = 0
      if $use_threads and not $threads_loaded;

   usage() if not $result;
   usage() if $help_flag;

   if ($max_workers !~ /^auto/) {
      if (not looks_like_number($max_workers) && $max_workers > 0) {
         print STDERR "$prog_name: $max_workers: invalid max workers\n";
         exit 2;
      }
   }

   usage() unless defined $ARGV[0];

   $run_mode = MODE_PRINT if $print_flag;
   $run_mode = MODE_SUM   if $sum_flag;
}

## Validation.

my $F_arg = (defined $ARGV[1]) ? eval $ARGV[0] : 1;
my $N_arg = (defined $ARGV[1]) ? eval $ARGV[1] : eval $ARGV[0];

Sandbox::check_numbers($prog_name, $max_number, $F_arg, $N_arg, $sum_flag);

my $F = $F_arg + 0;
my $N = $N_arg + 0;

###############################################################################
## ----------------------------------------------------------------------------
## Include C functions.
##
## Specifying -std=c99 fails under the Windows environment due to several
## header files not c99 compliant. The -march=native option is not supported
## by the MinGW compiler. Update ExtUtils::MakeMaker if compiling fails
## under Cygwin. Specify CCFLAGSEX, not CCFLAGS.
##
###############################################################################

BEGIN {
   $ENV{PERL_INLINE_DIRECTORY} = "${base_dir}/.Inline";
   mkdir "${base_dir}/.Inline" unless -d "${base_dir}/.Inline";
}

use Inline 'C' => Config =>
   CCFLAGSEX => "-I${base_dir}/src -O2 -fsigned-char -fomit-frame-pointer",
   TYPEMAPS => "${base_dir}/src/typemap";

use Inline 'C' => "${base_dir}/src/algorithm3.c";

###############################################################################
## ----------------------------------------------------------------------------
## Instantiate a MCE instance.
##
###############################################################################

## Step size must be a factor of 6. Do not increase beyond the maximum below.
## Sieve size must be a factor of 510510 for the pre-sieving logic:
## (2)(3) pre-sieves (5)(7)(11)(13)(17).

my ($factor, $sieve_size, $step_size);
my $F_adj = $F - ($F % 6) + 1;

$factor =
   ($N >= 1e19) ? .5 : ($N >= 1e18) ?  1 : ($N >= 1e17) ?  2 :
   ($N >= 1e16) ?  3 : ($N >= 1e15) ?  5 : ($N >= 1e14) ?  8 :
   ($N >= 1e13) ? 13 : ($N >= 1e12) ? 21 : ($N >= 1e11) ? 34 :
   ($N >= 1e10) ? 55 : ($N >= 1e9 ) ? 89 : 144;

$sieve_size  = int(16e7 / $factor * 3);
$sieve_size -= $sieve_size % 510510;
$sieve_size  = 510510 if $sieve_size < 510510;

$step_size = $sieve_size * int(($N + 1 - $F_adj) / $sieve_size / 5e4 + 1);

my $mce = MCE->new(

   gather => Sandbox::o_iter($F_adj, $N, $step_size, $quiet_flag, $run_mode),
   input_data => Sandbox::i_iter($F_adj, $N, $step_size),

   max_workers => (($F == $N) ? 1 : $max_workers),
   use_threads => $use_threads,

   user_func => sub {
      my ($mce, $chunk_ref, $chunk_id) = @_;

      my ($limit, $low, $high, $output_fh);
      my $start = $chunk_ref->[0];
      my $output_fd = 0;
      my $n_agg = 0;

      if ($run_mode == MODE_PRINT) {
         open $output_fh, ">", "$tmp_dir/$chunk_id" or
            die "$prog_name: cannot open '$tmp_dir/$chunk_id' for writing\n";

         $output_fd = fileno $output_fh;
      }

      $limit = ($max_number - $start <= $step_size)
         ? $N : Sandbox::min($start + $step_size - 1, $N);

      for ($low = $start; $low <= $limit; $low += $sieve_size) {

         $high = ($max_number - $low <= $sieve_size)
            ? $limit : Sandbox::min($low + $sieve_size - 1, $limit);

         my $p = practicalsieve($low, $high, $run_mode, $output_fd);

         if ($run_mode != MODE_PRINT) {
            $n_agg += $p->[0];
         }
         elsif ($p->[0] < 0) {
            MCE->abort();
            last;
         }

         last if ($limit - $low < $sieve_size);
      }

      close $output_fh if $run_mode == MODE_PRINT;

      MCE->gather(($run_mode == MODE_PRINT) ? $chunk_id : $n_agg);

      return;
   }
);

###############################################################################
## ----------------------------------------------------------------------------
## Run.
##
###############################################################################

syswrite(\*STDERR, "  0%\r") unless $quiet_flag;
my $start = time();

practicalsieve_init($F, $F_adj, $N, $sieve_size);

$mce->run();

practicalsieve_finish();

exit(Sandbox::end($quiet_flag, $run_mode, time() - $start));

