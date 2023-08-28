
package Sandbox;

use strict;
use warnings;

our $VERSION = '1.001';

## use bigint;

use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(sleep);
use Fcntl qw(O_RDONLY);

use constant {
   MODE_COUNT => 1,
   MODE_PRINT => 2,
   MODE_SUM   => 3
};

sub import {
   no strict 'refs'; no warnings 'redefine';
   my $pkg = caller();
   *{ $pkg . '::MODE_COUNT' } = \&MODE_COUNT;
   *{ $pkg . '::MODE_PRINT' } = \&MODE_PRINT;
   *{ $pkg . '::MODE_SUM'   } = \&MODE_SUM;
   return;
}

sub min {
   return $_[ ($_[0] + 0 > $_[1] + 0) ];
}

our $N_agg = 0;

###############################################################################
## ----------------------------------------------------------------------------
## Check numbers.
##
###############################################################################

sub check_numbers
{
   my ($prog_name, $max_number, $F_arg, $N_arg, $sum_flag) = @_;
   local $@; no warnings;

   die "$prog_name: invalid integer or range.\n" unless
      looks_like_number($F_arg) && int($F_arg) == $F_arg && $F_arg > 0 &&
      looks_like_number($N_arg) && int($N_arg) == $N_arg && $N_arg > 0 &&
      $N_arg >= $F_arg;

   die "$prog_name: sum: 29505444490 is the maximum limit allowed.\n"
      if $sum_flag && $N_arg > 29505444490;

   die "$prog_name: integer exceeds $max_number 2^64-1-6.\n"
      if min($max_number, $N_arg) ne $N_arg;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Input/output iterators for MCE.
##
###############################################################################

sub i_iter
{
   my ($F, $N, $step_size) = @_;
   my $n_seq;

   return sub {
      return $n_seq = $F if (not $n_seq);
      return if ($n_seq + $step_size > $N);
      return $n_seq += $step_size;
   }
}

sub o_iter
{
   my ($F, $N, $quiet_flag, $run_mode) = @_;
   my $show_progress = $quiet_flag ? 0 : 1;
   my ($completed, $last_completed);

   return sub {
      my ($ret, $high, $wid) = @_;

      if ($show_progress && $wid == 1) {
         $completed = int(($F == $N) ? 99 : ($high - $F) / ($N - $F) * 100 + 0.5);
         if (!defined $last_completed || $last_completed != $completed) {
            $completed = 99 if $completed > 99;
            $last_completed = $completed;
            syswrite(\*STDERR, "  $last_completed%\r");
         }
      }

      if ($run_mode != MODE_PRINT) {
         $N_agg += $ret;
      }
      else {
         my $file = MCE->tmp_dir() . "/$ret";
         $N_agg = 1 if -s $file;
         unlink $file;
      }

      return;
   };
}

###############################################################################
## ----------------------------------------------------------------------------
## Display prime numbers to STDOUT.
##
###############################################################################

sub display
{
   my ($chunk_id, $file) = @_;
   my ($fh, $n_read, $buf);

   if (-s $file) {
      syswrite(\*STDERR, "      \r") if $chunk_id == 1;
      sysopen($fh, $file, O_RDONLY);
      $buf = sprintf("%49152s", "");

      while (1) {
         $n_read = sysread($fh, $buf, 49152, 0);
         last if $n_read == 0;
         syswrite(\*STDOUT, $buf, $n_read);
      }

      close $fh;
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## The end.
##
###############################################################################

sub end
{
   my ($quiet_flag, $run_mode, $lapse) = @_;

   if ($quiet_flag) {
      print $N_agg, "\n" if $run_mode != MODE_PRINT;
   }
   else {
      if ($lapse > 0.125) {
         syswrite(\*STDERR, "  100%\r");
         sleep(0.08);
      }
      syswrite(\*STDERR, "      \r");

      print  STDERR "Primes found: ", $N_agg, "\n" if $run_mode == MODE_COUNT;
      print  STDERR "Sum of primes: ", $N_agg, "\n" if $run_mode == MODE_SUM;
      printf STDERR "Seconds: %0.03f\n", $lapse;
   }

   return ($N_agg > 0) ? 0 : 1;
}

1;

