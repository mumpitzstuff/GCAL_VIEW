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
use JSON;
use utf8;
use Encode qw(encode_utf8 decode_utf8);
use Storable qw(freeze thaw);


sub GCALVIEW_Initialize($)
{
  my ($hash) = @_;

  $hash->{DefFn}    = 'GCALVIEW_Define';
  $hash->{UndefFn}  = 'GCALVIEW_Undefine';
  $hash->{NotifyFn} = 'GCALVIEW_Notify'; 
  $hash->{SetFn}    = 'GCALVIEW_Set';
  $hash->{GetFn}    = 'GCALVIEW_Get';
  $hash->{AttrFn}   = 'GCALVIEW_Attr';
  $hash->{AttrList} = 'updateInterval '.
                      'calendarDays '.
                      'calendarType:standard,waste '.
                      'readingPrefix:1 '.
                      'wasteEventSeparator '.
                      'alldayText '.
                      'weekdayText '.
                      'maxEntries '.
                      'includeStarted:0 '.
                      'sourceColor:textField-long '.
                      'disable:1 '.
                      'cache:0 '.
                      'filterSummary '.
                      'filterLocation '.
                      'filterDescription '.
                      'filterSource '.
                      'filterAuthor '.
                      'filterOverall '.
                      #'oauthToken '.
                      $readingFnAttributes;

  return undef;
}


sub GCALVIEW_Define($$)
{
  my ($hash, $def) = @_;
  my @args = split("[ \t][ \t]*", $def);
  
  return 'Usage: define <name> GCALVIEW <timeout>'  if (@args < 3);
  
  my ($name, $type, $timeout) = @args;
  return 'The timeout value has to be at least 10s'  if ($timeout < 10);
  
  $hash->{NOTIFYDEV} = 'global'; 
  $hash->{TIMEOUT} = $timeout;

  delete $hash->{helper}{RUNNING_PID};
  
  $attr{$name}{'updateInterval'} = 3600 if (!defined($attr{$name}{'updateInterval'}));
  
  readingsSingleUpdate($hash, 'state', 'Initialized', 1);

  Log3 $name, 3, 'GCALVIEW defined with timeout '.$timeout;

  return undef;
}


sub GCALVIEW_Undefine($$)
{
  my ($hash, $arg) = @_;
  
  RemoveInternalTimer($hash);
  BlockingKill($hash->{helper}{RUNNING_PID}) if (defined($hash->{helper}{RUNNING_PID}));
  
  return undef;
}


sub GCALVIEW_Notify($$)
{
  my ($hash, $dev) = @_;
  
  return if (!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));

  if (IsDisabled($hash->{NAME})) 
  {
    readingsSingleUpdate($hash, 'state', 'disabled', 0);
  }
  else
  {
    GCALVIEW_SetNextTimer($hash, 15);
  }
  
  return undef;
} 


sub GCALVIEW_Attr($$$$) {
  my ($command, $name, $attribute, $value) = @_;
  my $hash = $defs{$name};

  if ($command eq 'set') 
  {
    if ($attribute eq 'updateInterval')
    {
      if (($value !~ /^\d+$/) || ($value < 60))
      {
        return 'updateInterval is required in s (default: 3600, min: 60)';
      }
    }
    elsif ($attribute eq 'disable')
    {
      if ($value eq '1')
      {
        RemoveInternalTimer($hash);
        
        readingsSingleUpdate($hash, 'state', 'disabled', 1);
      }
      else
      {
        GCALVIEW_SetNextTimer($hash, 0);
        
        readingsSingleUpdate($hash, 'state', 'Initialized', 1);
      }
    }
    elsif ($attribute eq 'calendarDays')
    {
      if ($value !~ /^\d+$/)
      {
        return 'calendarDays is required in days (any positive number)';
      }
    }
    elsif ($attribute eq 'sourceColor')
    {
      my $fail = 0;
      my @sourceColors = split('\s*,\s*' , $value);
            
      if (@sourceColors)
      {
        foreach (@sourceColors)
        { 
          @_ = split('\s*:\s*', $_);
          
          if (!@_)
          {
            $fail = 1;
            last;
          }
        }
      }
      else
      {
        $fail = 1;
      }
      
      if ($fail)
      {
        return 'sourceColor is required in format: <source>:<color>,<source>:<color>,...';
      }
    }
    elsif ($attribute eq 'maxEntries')
    {
      if (($value !~ /^\d+$/) || ($value > 200) || (0 == $value))
      {
        return 'maxEntries must be a number and is limited to the range: 1 - 200';
      }
    }
    elsif ($attribute eq 'weekdayText')
    {
      @_ = split('\s*,\s*', $value);
      
      if (scalar(@_) != 7)
      {
        return 'weekdayText must be a comma separated list of 7 days: Monday,Tuesday,...';
      }
    }
    elsif ($attribute eq 'filterSummary' ||
           $attribute eq 'filterLocation' ||
           $attribute eq 'filterDescription' ||
           $attribute eq 'filterSource' ||
           $attribute eq 'filterAuthor' ||
           $attribute eq 'filterOverall')
    {
      eval{qr/$value/};
      
      if ($@)
      {
        return 'regular expression is wrong: '.$@;
      }        
    }
    #elsif ($attribute eq 'oauthToken')
    #{
      #my ($fh, $filename) = tempfile();
      #
      #print($fh, $value."\n");
      #seek($fh, 0, 0);      
      #
      #my $calList = qx(gcalcli list --noauth_local_webserver < $filename);
      #   
      #if ($? || $stdout !~ /Authentication successful/)
      #{
      #  Log3 $name, 3, $name.': something went wrong (oauth token can not be set) - '.$stdout;
      #  
      #  return 'Authentication failed!';
      #}
      #else
      #{
      #  Log3 $name, 3, $name.': Authentication successfully completed.';
      #  
      #  return 'Authentication successfully completed! stdout: '.$stdout.' stderr: '.$stderr;
      #}
    #}
  }
 
  return undef;
}


sub GCALVIEW_SetNextTimer($$)
{
  my ($hash, $timer) = @_;
  
  Log3 $hash->{NAME}, 5, $hash->{NAME}.'_SetNextTimer: set next timer';
  
  RemoveInternalTimer($hash);
  if (!defined($timer))
  {
    InternalTimer(gettimeofday() + AttrVal($hash->{NAME}, 'updateInterval', 3600), 'GCALVIEW_Start', $hash, 0);
  }
  else
  {
    InternalTimer(gettimeofday() + int(rand(30)) + $timer, 'GCALVIEW_Start', $hash, 0);
  }
}


sub GCALVIEW_Set($$@) {
  my ($hash, $name, @aa) = @_;
  my ($cmd, $arg) = @aa;
    
  if ($cmd eq 'update') 
  {
    GCALVIEW_Start($hash);
  }
  else 
  {
    my $list = 'update:noArg';
      
    return 'Unknown argument '.$cmd.', choose one of '.$list;
  }

  return undef;
}


sub GCALVIEW_Get($$@) {
  my ($hash, $name, @aa) = @_;
  my ($cmd, $arg) = @aa;
    
  #if ($cmd eq 'authenticationURL') 
  #{
  #  my ($calList, $result) = ($_ = qx(gcalcli list --noauth_local_webserver 2>&1 /dev/null), $? >> 8);
  #      
  #  if ((0 != $result) &&
  #      ($calList =~ /(https\:\/\/accounts\.google\.com[^\n]+)/)) 
  #  {
  #    return $1;      
  #  }
  #  else
  #  {      
  #    # nothing to do because already authenticated
  #    return 'Authentication seems to be already done.';
  #  }
  #}
  #else 
  #{
  #  my $list = 'authenticationURL:noArg';
  #    
  #  return 'Unknown argument '.$cmd.', choose one of '.$list;
  #}

  return undef;
} 


sub GCALVIEW_Start($)
{
  my ($hash) = @_;

  return undef if (IsDisabled($hash->{NAME}));

  if (exists($hash->{helper}{RUNNING_PID})) 
  {
    Log3 $hash->{NAME}, 3, $hash->{NAME}.' blocking call already running';
    
    GCALVIEW_DoAbort($hash);
  }
  
  GCALVIEW_SetNextTimer($hash, undef);
    
  $hash->{helper}{RUNNING_PID} = BlockingCall('GCALVIEW_DoRun', $hash->{NAME}, 'GCALVIEW_DoEnd', $hash->{TIMEOUT}, 'GCALVIEW_DoAbort', $hash);
}


sub GCALVIEW_DoRun(@)
{
  my ($name) = @_;
  my @calList = ();
  my $calData = '';
  my $result;
  my $calendarDays = AttrVal($name, 'calendarDays', undef);
  my $calendarPeriod = '';
  my $calFilter = AttrVal($name, 'calendarFilter', undef);
  my $noStarted = (0 == AttrVal($name, 'includeStarted', 1) ? '--nostarted' : '');
  my $noCache = (0 == AttrVal($name, 'cache', 1) ? '--nocache' : '');
  my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
  my $today = sprintf('%02d/%02d/%04d', $mon + 1, $mday, $year + 1900);
   
  Log3 $name, 5, $name.'_DoRun: start running';
  
  # calendar filter attribute already set? 
  if (!defined($calFilter))
  {
    # get list of calendars
    ($calData, $result) = ($_ = qx(gcalcli list 2>&1), $? >> 8);
    
    if (0 != $result)
    {
      Log3 $name, 3, $name.": gcalcli list";
      Log3 $name, 3, $name.': something went wrong (check your parameters) - '.$calData if defined($calData);
      
      $calData = '';
    }
    else
    {
      Log3 $name, 5, $name.': '.$calData;
      
      while (m/(?:owner|reader)\s+(.+)\s*/g)
      {
        push(@calList, $1);
      }
    }
    
    $calFilter = '';
  }
  else
  {
    # filter calendars if attribute calFilter is available
    @_ = split(/\s*,\s*/, $calFilter);
    
    for (@_) 
    {
      $_ = '"'.$_.'"';
    }
    
    $calFilter = '--calendar '.join(' --calendar ', @_);
  }
  
  # calculate end date if needed (5 days is the default)
  if (defined($calendarDays))
  {
    ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time + (86400 * $calendarDays));
    
    $calendarPeriod = $today.' '.sprintf('%02d/%02d/%04d', $mon + 1, $mday, $year + 1900);
  }
  
  # get all calendar entries
  ($calData, $result) = ($_ = qx(gcalcli agenda $calendarPeriod $calFilter --detail_all $noStarted $noCache --tsv 2>&1), $? >> 8);  
  
  if (0 != $result)
  {
    Log3 $name, 3, $name.": gcalcli agenda $calendarPeriod $calFilter --detail_all $noStarted $noCache --tsv";
    Log3 $name, 3, $name.': something went wrong (check your parameters) - '.$calData if defined($calData);
    
    $calData = '';
  }
  else
  {
    # split the results by lines
    my @entry = split("\n" , $calData);
    my @calStruct = ();
    my $filterSummary = AttrVal($name, 'filterSummary', undef);
    my $filterLocation = AttrVal($name, 'filterLocation', undef);
    my $filterDescription = AttrVal($name, 'filterDescription', undef);
    my $filterSource = AttrVal($name, 'filterSource', undef);
    my $filterAuthor = AttrVal($name, 'filterAuthor', undef);
    my $filterOverall = AttrVal($name, 'filterOverall', undef);
    my $calendarType = AttrVal($name, 'calendarType', 'standard');
    my $sourceColor;
    my @sourceColors = split('\s*,\s*' , AttrVal($name, 'sourceColor', ''));
    my %groups;
    my $lastStartDate;
    
    
    Log3 $name, 5, $name.': '.$calData;
    
    foreach $_ (@entry)
    {
      # split each line by tabs
      @_ = split("\t", $_);
      
      # output must have exactly 11 fields of data
      if (11 == scalar(@_))
      {
        # apply some content filters
        next if ((defined($filterSummary) && ($_[6] =~ /$filterSummary/)) ||
                 (defined($filterLocation) && ($_[7] =~ /$filterLocation/)) ||
                 (defined($filterDescription) && ($_[8] =~ /$filterDescription/)) ||
                 (defined($filterSource) && ($_[9] =~ /$filterSource/)) ||
                 (defined($filterAuthor) && ($_[10] =~ /$filterAuthor/)) ||
                 (defined($filterOverall) && (($_[6] =~ /$filterOverall/) || 
                                              ($_[7] =~ /$filterOverall/) ||
                                              ($_[8] =~ /$filterOverall/) ||
                                              ($_[9] =~ /$filterOverall/) ||
                                              ($_[10] =~ /$filterOverall/))));      
      
        # eliminate events with the same summary if type waste is active
        if ('waste' eq $calendarType)
        {
          #Log3 $name, 5, $name.': '.join(', ', @_);
          
          if (!exists($groups{$_[6]}))
          {
            $groups{$_[6]} = 1;
          }
          else
          {
            next;
          }
          
          # join the event with same start date
          #if (!defined($lastStartDate) ||
          #    ($lastStartDate ne $_[0]))
          #{
          #  $lastStartDate = $_[0];
          #}          
          #else
          #{
          #  # join the event summary
          #  $calStruct[$#calStruct][6] .= ' '.$_[6];
          #  
          #  next;
          #}
        }
        
        # generate source color and add an additional data field
        $sourceColor = 'white';
        foreach (@sourceColors)
        { 
          my ($source, $color) = split('\s*:\s*', $_); 
          
          if (-1 != index($_[9], $source))
          { 
            $sourceColor = $color;
            
            last;
          }
        };
        
        push(@_, $sourceColor);
        push(@calStruct, [@_]);
      }
      else
      {
        Log3 $name, 3, $name.': something went wrong (invalid gcalcli output) - '.join(', ', @_);
      }
    }
    
    # encode filtered calendar entries
    #$calData = eval {encode_json(\@calStruct)};
    $calData = eval {encode_base64(freeze(\@calStruct), '')};
    
    if ($@) 
    {           
      Log3 $name, 3, $name.': encode_json failed: '.$@;
    }
    
    #Log3 $name, 5, $name.': '.$calData;
  }
  
  # encode calendar list
  $_ = encode_base64(join(',', @calList), '');

  return $name.'|'.$_.'|'.$calData;
}


sub GCALVIEW_DoEnd($)
{
  my ($string) = @_;
  my ($name, $calList, $calDataJson) = split("\\|", $string);
  my $hash = $defs{$name};
  my @calData = ();
  my $cterm_new = 0;
  my $ctoday_new = 0;
  my $ctomorrow_new = 0;
  my $calendarType = AttrVal($name, 'calendarType', 'standard');
  my $daysUntilNext = 0;
     
  Log3 $name, 5, $name.'_DoEnd: end running';
  
  # decode results
  $calList = decode_base64($calList);
  #@calData = eval {@{decode_json($calDataJson)} if ('' ne $calDataJson)};
  @calData = eval {@{thaw(decode_base64($calDataJson))} if ('' ne $calDataJson)};
  
  if ($@) 
  {           
    Log3 $name, 3, $name.': decode_json failed: '.$@;
  }
  
  if ('' ne $calList)
  {
    $calList =~ s/\s/#/g;
    addToDevAttrList($name, 'calendarFilter:multiple-strict,'.$calList);
  }
  
  # clear all readings
  delete($hash->{READINGS});
  
  # start update of readings
  readingsBeginUpdate($hash);
  
  if (scalar(@calData))
  {
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
    my $weekday = $wday;
    my $today = sprintf('%02d.%02d.%04d', $mday, $mon + 1, $year + 1900);
    ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time + 86400);
    my $tomorrow = sprintf('%02d.%02d.%04d', $mday, $mon + 1, $year + 1900); 
    my $weekDayArr = AttrVal($name, 'weekdayText', undef);
    my $alldayText = AttrVal($name, 'alldayText', 'all-day');
    my $wasteEventSeparator = AttrVal($name, 'wasteEventSeparator', ' and ');
    my @readingPrefix = ('standard' eq $calendarType) ? ('t_', 'today_', 'tomorrow_') : ((1 == AttrVal($name, 'readingPrefix', 0)) ? ($name.'_') : (''));
    my $nowText = undef;
    my $nowDescription = '';
    my $nextDate = undef;
    my $nextText = '';
    my $nextDescription = '';
    my %umlaute = ("ä" => "ae", "Ä" => "Ae", "ü" => "ue", "Ü" => "Ue", "ö" => "oe", "Ö" => "Oe", "ß" => "ss");
      
    foreach (@calData)
    {
      # mapping
      # 0 = start date
      # 1 = start time
      # 2 = end date
      # 3 = end time
      # 4 = link
      # 5 = ?
      # 6 = summary
      # 7 = location
      # 8 = description
      # 9 = calendar
      # 10 = author
      # additional generated attribute
      # 11 = sourcecolor
            
      my $startDate = @$_[0];
      my $startTime = @$_[1];
      my $endDate = @$_[2];
      my $endTime = @$_[3];
      my $url = @$_[4];
      my $summary = @$_[6];
      my $location = @$_[7];
      my $description = @$_[8];
      my $calendar = @$_[9];
      my $author = @$_[10];
      my $sourceColor = @$_[11];
      my ($startYear, $startMonth, $startDay) = split("-", $startDate);
      my ($endYear, $endMonth, $endDay) = split("-", $endDate);
      my $eventDate = fhemTimeLocal(0, 0, 0, $startDay, $startMonth - 1, $startYear - 1900);
      my $daysleft = floor(($eventDate - time) / 60 / 60 / 24 + 1);
      my $daysleftLong;
      my $startDateStr = $startDay.'.'.$startMonth.'.'.$startYear;
      my $endDateStr = $endDay.'.'.$endMonth.'.'.$endYear;
      my $timeShort;
      my $weekdayStr;
    
      # fix daysleft if event is already running
      $daysleft = 0 if ($daysleft < 0);      
      
      # generate string daysleft
      if (0 == $daysleft)
      {
        $daysleftLong = 'today';
      }
      elsif (1 == $daysleft)
      {
        $daysleftLong = 'tomorrow';
      }
      else
      {
        $daysleftLong = 'in '.$daysleft.' days';
      }
      
      # generate timeshort
      if (($startTime eq "00:00") && ($endTime eq "00:00") && ($startDate ne $endDate))
      {
        $timeShort = $alldayText;
      }
      else
      {
        $timeShort = $startTime.' - '.$endTime;
      }
      
      # generate weekdaytext
      if (!defined($weekDayArr))
      {
        @_ = ('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday');
        $weekdayStr = $_[(($weekday - 1 + $daysleft) % 7)];        
      }
      else
      {
        @_ = split('\s*,\s*', $weekDayArr);
        $weekdayStr = $_[(($weekday - 1 + $daysleft) % 7)];
      }
      
      # loop 3 times to generate the overall appointment list, the appointment list for today and the appointment list for tomorrow
      for (my $i = 0; $i < 3; $i++)
      {
        if ((0 == $i) ||
            ((1 == $i) && ('standard' eq $calendarType) && ($startDateStr eq $today)) || 
            ((2 == $i) && ('standard' eq $calendarType) && ($startDateStr eq $tomorrow)))
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
          
          if ('waste' eq $calendarType)
          {
            my $readingName = decode('UTF-8', $summary);
            $readingName =~ s/ /_/g;
            eval 
            {
              use utf8;
              $readingName =~ s/([äÄüÜöÖß])/$umlaute{$1}/eg;
            };
            $readingName =~ tr/a-zA-Z0-9\-_//dc;
            
            readingsBulkUpdate($hash, $readingPrefix[$i].$readingName.'_date', $startDateStr);
            readingsBulkUpdate($hash, $readingPrefix[$i].$readingName.'_days', $daysleft);
            readingsBulkUpdate($hash, $readingPrefix[$i].$readingName.'_location', $location);
            readingsBulkUpdate($hash, $readingPrefix[$i].$readingName.'_description', $description);
            readingsBulkUpdate($hash, $readingPrefix[$i].$readingName.'_text', $summary);
            readingsBulkUpdate($hash, $readingPrefix[$i].$readingName.'_weekday', $weekdayStr);
            readingsBulkUpdate($hash, $readingPrefix[$i].$readingName.'_url', '<html><a href="'.$url.'" target="_blank">link</a></html>');

            if (0 == $daysleft)
            {
              if (defined($nowText))
              {
                $nowText .= $wasteEventSeparator.$summary;
                $nowDescription .= $wasteEventSeparator.$description if ($nowDescription ne $description);
                
                readingsBulkUpdate($hash, 'now_text', $nowText);
                readingsBulkUpdate($hash, 'now_description', $nowDescription);
              }
              else
              {
                readingsBulkUpdate($hash, 'now_date', $startDateStr);
                readingsBulkUpdate($hash, 'now_location', $location);
                readingsBulkUpdate($hash, 'now_description', $description);
                readingsBulkUpdate($hash, 'now_text', $summary);
                readingsBulkUpdate($hash, 'now_weekday', $weekdayStr);
                readingsBulkUpdate($hash, 'now_url', '<html><a href="'.$url.'" target="_blank">link</a></html>');
              
                $nowText = $summary;
                $nowDescription = $description;
              }
            }
            
            if (defined($nextDate))
            {
              if ($nextDate eq $startDateStr)
              {
                $nextText .= $wasteEventSeparator.$summary;
                $nextDescription .= $wasteEventSeparator.$description if ($nextDescription ne $description);
                
                readingsBulkUpdate($hash, 'next_text', $nextText);
                readingsBulkUpdate($hash, 'next_description', $nextDescription);
              }
            }
            elsif ($daysleft > 0)
            {
              readingsBulkUpdate($hash, 'next_date', $startDateStr);
              readingsBulkUpdate($hash, 'next_days', $daysleft);
              readingsBulkUpdate($hash, 'next_location', $location);
              readingsBulkUpdate($hash, 'next_description', $description);
              readingsBulkUpdate($hash, 'next_text', $summary);
              readingsBulkUpdate($hash, 'next_weekday', $weekdayStr);
              readingsBulkUpdate($hash, 'next_url', '<html><a href="'.$url.'" target="_blank">link</a></html>');
              
              $nextDate = $startDateStr;
              $nextText = $summary;
              $nextDescription = $description;
              $daysUntilNext = $daysleft;
            }
          }
          else
          {          
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_bdate', $startDateStr);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_btime', $startTime);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_daysleft', $daysleft);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_daysleftLong', $daysleftLong);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_edate', $endDateStr);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_etime', $endTime);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_location', $location);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_description', $description);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_author', $author);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_source', $calendar);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_sourcecolor', $sourceColor);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_summary', $summary);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_timeshort', $timeShort);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_weekday', $weekdayStr);
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_url', '<html><a href="'.$url.'" target="_blank">link</a></html>');
          }
          
          $$counter++;
        }
      }
      
      last if ($cterm_new >= AttrVal($name, 'maxEntries', 200));
    }
  }
        
  if ('waste' eq $calendarType)
  {
    readingsBulkUpdate($hash, 'state', $daysUntilNext);
  }
  else
  {
    readingsBulkUpdate($hash, 'c-term', $cterm_new);
    readingsBulkUpdate($hash, 'c-today', $ctoday_new);
    readingsBulkUpdate($hash, 'c-tomorrow', $ctomorrow_new);
    readingsBulkUpdate($hash, 'state', 't: '.$cterm_new.' td: '.$ctoday_new.' tm: '.$ctomorrow_new);
  }
  readingsEndUpdate($hash, 1); 
  
  delete($hash->{helper}{RUNNING_PID});
}


sub GCALVIEW_DoAbort($)
{
  my ($hash) = @_;
  
  delete($hash->{helper}{RUNNING_PID});
  
  Log3 $hash->{NAME}, 3, 'BlockingCall for '.$hash->{NAME}.' aborted';
}

1;

=pod
=begin html

<a name="GCALVIEW"></a>
<h3>GCALVIEW</h3>

<ul>
  <u><b>Calender Viewer for Google Calendar</b></u>
  <br><br>
  This calendar can show you all events in a certain period of time. There are many options to filter
  the data and adapt the output to your needs. This module has 2 modes, a standard mode which behaves like 
  57_CALVIEW and a waste mode which behaves like 57_ABFALL. You can easily switch back and forth between 
  the two modes to customize the calendar to suit your needs. The module is completely non blocking but 
  needs to have gcalcli installed.   
  <br><br>
  <a name="GCALVIEWinstallation"></a>
  <b>Installation</b>
  <ul><br>
    You have to install gcalcli first and to get a valid OAuth token directly from Google.<br><br>
    <code>sudo apt-get install gcalcli</code><br>
    <code>sudo pip install gcalcli</code><br><br>
    Now check if the user fhem is able to open a bash shell (just needed temporary and can be reverted after the OAuth token was installed).<br><br>
    <code>sudo nano /etc/passwd</code><br><br>
    Search for user fhem and replace /bin/false with /bin/bash if needed.<br><br>
    <code>gcalcli list --noauth_local_webserver</code><br><br>
    Copy the URL into a browser and start it. Accept the connection to your Google Calendar and copy the OAuth token. Enter the token in your fhem console window and press enter.<br><br>
    <code>gcalcli list</code><br><br>
    Check if you can get a list of you calendars now and proceed if it was successful.<br>
    Exit the fhem bash and revert the change in /etc/passwd again just for security reasons.<br>
    Open you fhem installation within you browser now and do the following:<br><br>
    <code>update add http://raw.githubusercontent.com/mumpitzstuff/fhem-GCALVIEW/master/controls_gcalview.txt</code><br>
    <code>update all</code><br>
    <code>shutdown restart</code><br>
    <code>define &lt;name&gt; GCALVIEW &lt;timeout&gt;</code>
  </ul>
  <br><br>
  <a name="GCALVIEWdefine"></a>
  <b>Define</b>
  <ul><br>
    <code>define &lt;name&gt; GCALVIEW &lt;timeout&gt;</code>
    <br><br>
    Example:
    <ul><br>
      <code>define MyCalendar GCALVIEW 30</code><br>
    </ul>
    <br>
    This command creates a calendar with the name MyCalendar. If the background update process takes more time than the 
    timeout value allows, this process is aborted.
  </ul>
  <br><br>
  <a name="GCALVIEWset"></a>
  <b>Set</b>
  <ul>
    <li>update - update the calender content</li>
    <br>
  </ul>
  <br><br>
  <a name="GCALVIEWattribut"></a>
  <b>Attributes</b>
  <ul>
    <li><b>updateInterval:</b> update intervall in seconds (default: 3600 seconds)<br></li>
    <li><b>calendarFilter:</b> some calendars can be filtered (default: all calendars of a google account are activated)<br></li>
    <li><b>calendarDays:</b> defines the timespan in days (start is today). the default timespan is 5 days.<br></li>
    <li><b>calendarType:</b> <ul><li>standard - output like 57_CALVIEW</li>
                                 <li>waste - output like 57_ABFALL</li></ul><br></li>
    <li><b>includeStarted:</b> disable already started appointments of today (default: show already started appointments)<br></li>
    <li><b>maxEntries:</b> limit the maximum appointments (not more than 200 allowed)<br></li>
    <li><b>disable:</b> disable the module (no update anymore)<br></li>
    <li><b>cache:</b> disable the caching of calendar requests (default: cache activated)<br></li>
    <li><b>filterSummary:</b> regex to filter a summary (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>filterLocation:</b> regex to filter a location (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>filterDescription:</b> regex to filter a description (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>filterSource:</b> regex to filter a source (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>filterAuthor:</b> regex to filter an author (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>filterOverall:</b> regex to filter a summary, location, description, source or author (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>alldayText:</b> set the text for an allday event (default: all-day)<br></li>
    <li><b>weekdayText:</b> set the weekday text as comma separated list (default: Monday,Tuesday,Wednesday,Thursday,Friday,Saturday,Sunday)<br></li>
    <li><b>readingPrefix:</b> calendar name is used as reading prefix if type waste is active<br></li>
    <li><b>sourceColor:</b> set a color string based on source (Format: source:color,source:color,...)<br></li>
    <li><b>wasteEventSeparator:</b> separator for waste events if there are more than 1 event in one day<br></li>
    <br>
  </ul>
</ul>

=end html
=cut
