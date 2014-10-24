###############################################################################
## ----------------------------------------------------------------------------
## MCE::Core::Input::Request - Array_ref and Glob_ref input reader.
##
## This package provides the request chunk method used internally by the worker
## process. Distribution follows a bank-queuing model.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Input::Request;

our $VERSION = '1.517'; $VERSION = eval $VERSION;

## Items below are folded into MCE.

package MCE;

use strict;
use warnings;

## Warnings are disabled to minimize bits of noise when user or OS signals
## the script to exit. e.g. MCE_script.pl < infile | head

no warnings 'threads'; no warnings 'uninitialized';

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Request chunk.
##
###############################################################################

sub _worker_request_chunk {

   my MCE $self = $_[0]; my $_proc_type = $_[1];

   @_ = ();

   die "Private method called" unless (caller)[0]->isa( ref($self) );

   _croak("MCE::_worker_request_chunk: 'user_func' is not specified")
      unless (defined $self->{user_func});

   my $_chn         = $self->{_chn};
   my $_DAT_LOCK    = $self->{_dat_lock};
   my $_DAT_W_SOCK  = $self->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK  = $self->{_dat_w_sock}->[$_chn];
   my $_lock_chn    = $self->{_lock_chn};
   my $_single_dim  = $self->{_single_dim};
   my $_chunk_size  = $self->{chunk_size};
   my $_use_slurpio = $self->{use_slurpio};
   my $_RS          = $self->{RS} || $/;
   my $_RS_FLG      = (!$_RS || $_RS ne $LF);
   my $_I_FLG       = (!$/ || $/ ne $LF);
   my $_wuf         = $self->{_wuf};

   my ($_chunk_id, $_len, $_chunk_ref);
   my ($_output_tag, @_records);

   if ($_proc_type == REQUEST_ARRAY) {
      $_output_tag = OUTPUT_A_ARY;
   } else {
      $_output_tag = OUTPUT_S_GLB;
      @_records    = ();
   }

   ## -------------------------------------------------------------------------

   $self->{_next_jmp} = sub { goto _WORKER_REQUEST_CHUNK__NEXT; };
   $self->{_last_jmp} = sub { goto _WORKER_REQUEST_CHUNK__LAST; };

   _WORKER_REQUEST_CHUNK__NEXT:

   while (1) {

      ## Don't declare $_buffer with other vars above, instead it's done here.
      ## Doing so will fail with Perl 5.8.0 under Solaris 5.10 on large files.

      my $_buffer;

      ## Obtain the next chunk of data.
      {
         local $\ = undef if (defined $\); local $/ = $LF if ($_I_FLG);

         flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
         print $_DAT_W_SOCK $_output_tag . $LF . $_chn . $LF;
         chomp($_len = <$_DAU_W_SOCK>);

         unless ($_len) {
            flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
            return;
         }

         chomp($_chunk_id = <$_DAU_W_SOCK>);
         read $_DAU_W_SOCK, $_buffer, $_len;

         flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
      }

      ## Call user function.
      if ($_proc_type == REQUEST_ARRAY) {
         if ($_single_dim && $_chunk_size == 1) {
            local $_ = $_buffer;
            $_wuf->($self, [ $_buffer ], $_chunk_id);
         }
         else {
            $_chunk_ref = $self->{thaw}($_buffer); undef $_buffer;
            local $_ = ($_chunk_size == 1) ? $_chunk_ref->[0] : $_chunk_ref;
            $_wuf->($self, $_chunk_ref, $_chunk_id);
         }
      }
      else {
         if ($_use_slurpio) {
            local $_ = \$_buffer;
            $_wuf->($self, \$_buffer, $_chunk_id);
         }
         else {
            if ($_chunk_size == 1) {
               local $_ = $_buffer;
               $_wuf->($self, [ $_buffer ], $_chunk_id);
            }
            else {
               {
                  local $/ = $_RS if ($_RS_FLG);
                  _sync_buffer_to_array(\$_buffer, \@_records);
               }
               local $_ = \@_records;
               $_wuf->($self, \@_records, $_chunk_id);
            }
         }
      }
   }

   _WORKER_REQUEST_CHUNK__LAST:

   return;
}

1;

