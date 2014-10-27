###############################################################################
## ----------------------------------------------------------------------------
## MCE::Core::Input::Handle - File_path and Scalar_ref input reader.
##
## This package provides the read handle method used internally by the worker
## process. Distribution follows a bank-queuing model.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Input::Handle;

our $VERSION = '1.519'; $VERSION = eval $VERSION;

## Items below are folded into MCE.

package MCE;

use strict;
use warnings;

use bytes;

## Warnings are disabled to minimize bits of noise when user or OS signals
## the script to exit. e.g. MCE_script.pl < infile | head

no warnings 'threads'; no warnings 'uninitialized';

my $_que_read_size = $MCE::_que_read_size;
my $_que_template  = $MCE::_que_template;

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Read handle.
##
###############################################################################

sub _worker_read_handle {

   my MCE $self = $_[0]; my $_proc_type = $_[1]; my $_input_data = $_[2];

   @_ = ();

   die "Private method called" unless (caller)[0]->isa( ref($self) );

   _croak("MCE::_worker_read_handle: 'user_func' is not specified")
      unless (defined $self->{user_func});

   my $_QUE_R_SOCK  = $self->{_que_r_sock};
   my $_QUE_W_SOCK  = $self->{_que_w_sock};
   my $_chunk_size  = $self->{chunk_size};
   my $_use_slurpio = $self->{use_slurpio};
   my $_parallel_io = $self->{parallel_io};
   my $_RS          = $self->{RS} || $/;
   my $_RS_FLG      = (!$_RS || $_RS ne $LF);
   my $_wuf         = $self->{_wuf};

   my ($_data_size, $_next, $_chunk_id, $_offset_pos, $_IN_FILE, $_tmp_cs);
   my @_records = (); $_chunk_id = $_offset_pos = 0;

   $_data_size = ($_proc_type == READ_MEMORY)
      ? length $$_input_data : -s $_input_data;

   if ($_chunk_size <= MAX_RECS_SIZE || $_proc_type == READ_MEMORY) {
      open    $_IN_FILE, '<', $_input_data or die "$_input_data: $!\n";
      binmode $_IN_FILE;
   } else {
      sysopen $_IN_FILE, $_input_data, O_RDONLY or die "$_input_data: $!\n";
   }

   ## -------------------------------------------------------------------------

   $self->{_next_jmp} = sub { goto _WORKER_READ_HANDLE__NEXT; };
   $self->{_last_jmp} = sub { goto _WORKER_READ_HANDLE__LAST; };

   _WORKER_READ_HANDLE__NEXT:

   while (1) {

      ## Don't declare $_buffer with other vars above, instead it's done here.
      ## Doing so will fail with Perl 5.8.0 under Solaris 5.10 on large files.

      my $_buffer;

      ## Obtain the next chunk_id and offset position.
      sysread $_QUE_R_SOCK, $_next, $_que_read_size;
      ($_chunk_id, $_offset_pos) = unpack($_que_template, $_next);

      if ($_offset_pos >= $_data_size) {
         syswrite $_QUE_W_SOCK, pack($_que_template, 0, $_offset_pos);
         close $_IN_FILE; undef $_IN_FILE;
         return;
      }

      $_chunk_id++;

      ## Read data.
      if ($_chunk_size <= MAX_RECS_SIZE) {        ## One or many records.
         local $/ = $_RS if ($_RS_FLG);
         seek $_IN_FILE, $_offset_pos, 0;

         if ($_chunk_size == 1) {
            $_buffer = <$_IN_FILE>;
         }
         else {
            if ($_use_slurpio) {
               $_buffer .= <$_IN_FILE> for (0 .. $_chunk_size - 1);
            }
            else {
               for (0 .. $_chunk_size - 1) {
                  $_records[$_] = <$_IN_FILE>;
                  unless (defined $_records[$_]) {
                     delete @_records[$_ .. $_chunk_size - 1];
                     last;
                  }
               }
            }
         }

         syswrite $_QUE_W_SOCK,
            pack($_que_template, $_chunk_id, tell $_IN_FILE);
      }
      else {                                      ## Large chunk.
         local $/ = $_RS if ($_RS_FLG);

         if ($_proc_type == READ_MEMORY) {
            if ($_parallel_io) {
               syswrite $_QUE_W_SOCK,
                  pack($_que_template, $_chunk_id, $_offset_pos + $_chunk_size);

               $_tmp_cs = $_chunk_size;
               seek $_IN_FILE, $_offset_pos, 0;

               if ($_offset_pos) {
                  $_tmp_cs -= length <$_IN_FILE> || 0;
               }

               if (read($_IN_FILE, $_buffer, $_tmp_cs) == $_tmp_cs) {
                  $_buffer .= <$_IN_FILE>;
               }
            }
            else {
               seek $_IN_FILE, $_offset_pos, 0;

               if (read($_IN_FILE, $_buffer, $_chunk_size) == $_chunk_size) {
                  $_buffer .= <$_IN_FILE>;
               }

               syswrite $_QUE_W_SOCK,
                  pack($_que_template, $_chunk_id, tell $_IN_FILE);
            }
         }
         else {
            if ($_parallel_io) {
               syswrite $_QUE_W_SOCK,
                  pack($_que_template, $_chunk_id, $_offset_pos + $_chunk_size);

               $_tmp_cs = $_chunk_size;

               if ($_offset_pos) {
                  seek $_IN_FILE, $_offset_pos, 0;
                  $_tmp_cs -= length <$_IN_FILE> || 0;
                  sysseek $_IN_FILE, tell $_IN_FILE, 0;
               }
               else {
                  sysseek $_IN_FILE, $_offset_pos, 0;
               }

               if (sysread($_IN_FILE, $_buffer, $_tmp_cs) == $_tmp_cs) {
                  seek $_IN_FILE, sysseek($_IN_FILE, 0, 1), 0;
                  $_buffer .= <$_IN_FILE>;
               }
            }
            else {
               sysseek $_IN_FILE, $_offset_pos, 0;

               if (sysread($_IN_FILE, $_buffer, $_chunk_size) == $_chunk_size) {
                  seek $_IN_FILE, sysseek($_IN_FILE, 0, 1), 0;
                  $_buffer .= <$_IN_FILE>;
               }
               else {
                  seek $_IN_FILE, sysseek($_IN_FILE, 0, 1), 0;
               }

               syswrite $_QUE_W_SOCK,
                  pack($_que_template, $_chunk_id, tell $_IN_FILE);
            }
         }
      }

      ## Call user function.
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
            if ($_chunk_size > MAX_RECS_SIZE) {
               local $/ = $_RS if ($_RS_FLG);
               _sync_buffer_to_array(\$_buffer, \@_records);
            }
            local $_ = \@_records;
            $_wuf->($self, \@_records, $_chunk_id);
         }
      }
   }

   _WORKER_READ_HANDLE__LAST:

   close $_IN_FILE; undef $_IN_FILE;

   return;
}

1;

