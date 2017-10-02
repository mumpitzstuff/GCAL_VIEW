##############################################################################
#
#     57_GCALVIEW.pm
#     FHEM module to visualize google calendar content.
#
#     Author: Achim Winkler
#
##############################################################################

package main;

use strict;
use warnings;
use Blocking;


sub GCALVIEW_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}    = "GCALVIEW_Set"; 
  $hash->{DefFn}    = "GCALVIEW_Define";
  $hash->{UndefFn}  = "GCALVIEW_Undefine";
  $hash->{AttrFn}   = "GCALVIEW_Attr";
  $hash->{AttrList} = "disable:1 updateInterval agendaDays includeStarted:1 ".$readingFnAttributes;

  return undef;
}

#####################################
# Define GCALVIEW device
sub GCALVIEW_Define($$)
{
  my ($hash, $def) = @_;
  my @args = split("[ \t][ \t]*", $def);
  
  return "Usage: define <name> GCALVIEW <timeout>"  if (@args < 3);
  
  my ($name, $type, $timeout) = @args;
  return "The timeout value has to be at least 10s"  if ($timeout < 10);
  
  $hash->{TIMEOUT} = $timeout;

  delete $hash->{helper}{RUNNING_PID};
  
  $attr{$name}{"updateInterval"} = 3600 if (!defined($attr{$name}{"updateInterval"}));
  
  readingsSingleUpdate($hash, "state", "Initialized", 1);
  
  Log3 $name, 3, "GCALVIEW defined with timeout ".$timeout;

  GCALVIEW_SetNextTimer($hash);

  return undef;
}

#####################################
# Undefine GCALVIEW device
sub GCALVIEW_Undefine($$)
{
  my ($hash, $arg) = @_;
  
  RemoveInternalTimer($hash);
  BlockingKill($hash->{helper}{RUNNING_PID}) if (defined($hash->{helper}{RUNNING_PID}));
  
  return undef;
}

#####################################
# Manage attribute changes
sub GCALVIEW_Attr($$$$) {
  my ($command, $name, $attribute, $value) = @_;
  my $hash = $defs{$name};

  Log3 $hash->{NAME}, 5, $hash->{NAME}."_Attr: Attr ".$attribute."; Value ".$value;

  if ($command eq "set") {
    if ($attribute eq "updateInterval")
    {
      if (($value !~ /^\d+$/) || ($value < 60))
      {
        return "updateInterval is required in s (default: 3600, min: 60)";
      }
      else
      {
        $attr{$name}{"updateInterval"} = $value;
      }
    }
    elsif ($attribute eq "disable")
    {
      if ($value eq "1")
      {
        RemoveInternalTimer($hash);
        
        readingsSingleUpdate($hash, "state", "disabled", 1);
      }
      else
      {
        GCALVIEW_SetNextTimer($hash);
        
        readingsSingleUpdate($hash, "state", "Initialized", 1);
      }
    }
    elsif ($attribute eq "agendaDays")
    {
      if ($value !~ /^\d+$/)
      {
        return "agendaDays is required in days";
      }
      else
      {
        $attr{$name}{"agendaDays"} = $value;
      }
    }
    elsif ($attribute eq "includeStarted")
    {
      $attr{$name}{"includeStarted"} = 1 if ($value eq "1");
    }
  }

  return undef;
}

#####################################
# Set next timer for GCALVIEW check
sub GCALVIEW_SetNextTimer($)
{
  my ($hash) = @_;
  
  Log3 $hash->{NAME}, 5, $hash->{NAME}."_SetNextTimer: set next timer";
  
  # Check state every X seconds
  RemoveInternalTimer($hash);
  InternalTimer(gettimeofday() + AttrVal($hash->{NAME}, "updateInterval", 3600), "GCALVIEW_Start", $hash, 0);
}

#####################################
# manually start the GCALVIEW check
sub GCALVIEW_Set($$@) {
    my ($hash, $name, @aa) = @_;
    my ($cmd, $arg) = @aa;
    
    if ($cmd eq 'update') {
        GCALVIEW_Start($hash);
    } else {
        my $list = "update:noArg";
        return "Unknown argument $cmd, choose one of $list";
    }

    return undef;
} 

#####################################
# Prepare and start the blocking call in new thread
sub GCALVIEW_Start($)
{
  my ($hash) = @_;

  return undef if (IsDisabled($hash->{NAME}));

  if (!(exists($hash->{helper}{RUNNING_PID}))) {
    GCALVIEW_SetNextTimer($hash);
    
    $hash->{helper}{RUNNING_PID} = BlockingCall("GCALVIEW_DoRun", $hash->{NAME}, "GCALVIEW_DoEnd", $hash->{TIMEOUT}, "GCALVIEW_DoAbort", $hash);
  } else {
    Log3 $hash->{NAME}, 3, $hash->{NAME}." blocking call already running";
    GCALVIEW_SetNextTimer($hash);
  }
}

#####################################
# BlockingCall DoRun in separate thread
sub GCALVIEW_DoRun(@)
{
  my ($string) = @_;
  my ($name, $timeout) = split("\\|", $string);
  my $agendaDays = AttrVal($name, "agendaDays", "");
  my $agendaPeriod = "";
  my $includeStarted = (1 == AttrVal($name, "includeStarted", 0) ? "--started" : "");
  my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
  my $today = sprintf('%02d/%02d/%04d', $mon + 1, $mday, $year + 1900);
   
  Log3 $name, 5, $name."_DoRun: start running";
  
  if ("" ne $agendaDays)
  {
    ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time + (86400 * $agendaDays));
    
    $agendaPeriod = $today." ".sprintf('%02d/%02d/%04d', $mon + 1, $mday, $year + 1900);
    
    #Log3 $name, 5, $name.": agendaPeriod is ".$agendaPeriod;
  }
  
  my ($calData, $result) = ($_ = qx(gcalcli agenda $agendaPeriod --detail_all $includeStarted --tsv 2>&1), $? >> 8);  
  
  if (0 != $result)
  {
    Log3 $name, 3, $name.": something went wrong (check your parameters)";
  }
  else
  {
    #Log3 $name, 5, $name.": ".$calData;
  
    $calData = encode_base64($calData, "");
  }

  return $name."|".$calData;
}

#####################################
# BlockingCall completed
sub GCALVIEW_DoEnd($)
{
  my ($string) = @_;
  my ($name, $calData) = split("\\|", $string);
  my $hash = $defs{$name};
  #my $cterm_old = ReadingsVal($name, "c-term", 0); 
  #my $ctoday_old = ReadingsVal($name, "c-today", 0);
  #my $ctomorrow_old = ReadingsVal($name, "c-tomorrow", 0);
  my $cterm_new = 0;
  my $ctoday_new = 0;
  my $ctomorrow_new = 0;
  my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
  my $weekday = $wday;
  my $today = sprintf('%02d.%02d.%04d', $mday, $mon + 1, $year + 1900);
  ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time + 86400);
  my $tomorrow = sprintf('%02d.%02d.%04d', $mday, $mon + 1, $year + 1900); 
  my @readingPrefix = ("t_", "today_", "tomorrow_");
  
  Log3 $name, 5, $name."_DoEnd: end running";
  
  delete($hash->{READINGS});
  
  $calData = decode_base64($calData);
  
  readingsBeginUpdate($hash);
  
  while ($calData =~ m/\s*([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)\s*\s*/g)
  {
    # mapping
    # 1 = start date
    # 2 = start time
    # 3 = end date
    # 4 = end time
    # 5 = link
    # 6 = ?
    # 7 = summary
    # 8 = where
    # 9 = description
    # 10 = calendar
    # 11 = author
    #Log3 $name, 5, $name.": entry".($cterm_new + 1)." #1 ".$1." #2 ".$2." #3 ".$3." #4 ".$4." #5 ".$5." #6 ".$6." #7 ".$7." #8 ".$8." #9 ".$9." #10 ".$10." #11 ".$11;  
    
    my $eventDate = fhemTimeLocal(0, 0, 0, substr($1, 8, 2), substr($1, 5, 2) - 1, substr($1, 0, 4) - 1900);
	my $daysleft = floor(($eventDate - time) / 60 / 60 / 24 + 1);
	my $daysleftLong;
	
    if (0 == $daysleft)
    {
      $daysleftLong = "today";
    }
	elsif (1 == $daysleft)
    {
      $daysleftLong = "tomorrow";
    }
    else
    {
      $daysleftLong = "in ".$daysleft." days";
    }
    
    for (my $i = 0; $i < 3; $i++)
    {
      if ((0 == $i) ||
          (1 == $i && substr($1, 8, 2).".".substr($1, 5, 2).".".substr($1, 0, 4) eq $today) ||
          (2 == $i && substr($1, 8, 2).".".substr($1, 5, 2).".".substr($1, 0, 4) eq $tomorrow))
      {
        my $counter;
        
        if (0 == $i)
        {
          $counter = \$cterm_new;
        }
        elsif (1 == $i)
        {
          $counter = \$ctoday_new;
        }
        elsif (2 == $i)
        {
          $counter = \$ctomorrow_new;
        }
        
        my $counterLength = 3 - length($$counter + 1);
        
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_bdate", substr($1, 8, 2).".".substr($1, 5, 2).".".substr($1, 0, 4));
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_btime", $2);
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_daysleft", $daysleft);
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_daysleftLong", $daysleftLong);
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_edate", substr($3, 8, 2).".".substr($3, 5, 2).".".substr($3, 0, 4));
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_etime", $4);
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_location", $8);
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_description", $9);
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_author", $11);
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_source", $10);
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_sourcecolor", "white");
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_summary", $7);
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_timeshort", $2." - ".$4);
        readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1)."_weekday", (0 == (($weekday + $daysleft) % 8)) ? 1 : (($weekday + $daysleft) % 8));
        
        $$counter++;
      }
    }
  }
  
  readingsBulkUpdate($hash, "c-term", $cterm_new);
  readingsBulkUpdate($hash, "c-today", $ctoday_new);
  readingsBulkUpdate($hash, "c-tomorrow", $ctomorrow_new);
  readingsBulkUpdate($hash, "state", "t: ".$cterm_new." td: ".$ctoday_new." tm: ".$ctomorrow_new);
  readingsEndUpdate($hash, 1); 
  
  delete($hash->{helper}{RUNNING_PID});
}

#####################################
# BlockingCall aborted e.g. in case of a timeout
sub GCALVIEW_DoAbort($)
{
  my ($hash) = @_;
  
  delete($hash->{helper}{RUNNING_PID});
  
  Log3 $hash->{NAME}, 3, "BlockingCall for ".$hash->{NAME}." aborted";
}

1;

=pod
=begin html

<a name="GCALVIEW"></a>
<h3>GCALVIEW</h3>

=end html
=cut
