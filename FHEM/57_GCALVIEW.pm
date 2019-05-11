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
                      'readingPrefix:0,1 '.
                      'wasteEventSeparator '.
                      'alldayText '.
                      'weekdayText '.
                      'emptyReadingText '.
                      'daysLeftLongText '.
                      'maxEntries '.
                      'sourceColor:textField-long '.
                      'showAge:0,1 '.
                      'ageSource:description,summary,location '.
                      'disable:0,1 '.
                      'cache:0,1 '.
                      'filterSummary '.
                      'filterLocation '.
                      'filterDescription '.
                      'filterSource '.
                      'filterAuthor '.
                      'filterOverall '.
                      'invertFilter:0,1 '.
                      'configFolder '.
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
  $hash->{VERSION} = '1.0.6';

  delete $hash->{helper}{RUNNING_PID};

  $attr{$name}{'updateInterval'} = 3600 if (!defined($attr{$name}{'updateInterval'}));

  readingsSingleUpdate($hash, 'state', 'Initialized', 1);

  Log3 $name, 3, $name.' defined with timeout '.$timeout;

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
    elsif ($attribute eq 'daysLeftLongText')
    {
      @_ = split('\s*,\s*', $value);

      if (scalar(@_) != 3)
      {
        return 'daysLeftLongText must be a comma separated list with 3 parts (today, tomorrow and in x days). Use % as number of days. default: today,tomorrow,in % days';
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



  return undef;
}


sub GCALVIEW_Start($)
{
  my ($hash) = @_;

  return undef if (IsDisabled($hash->{NAME}));

  if (exists($hash->{helper}{RUNNING_PID}))
  {
    Log3 $hash->{NAME}, 3, $hash->{NAME}.' blocking call already running';

    BlockingKill($hash->{helper}{RUNNING_PID}) if (defined($hash->{helper}{RUNNING_PID}));
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
  my $noCache = (0 == AttrVal($name, 'cache', 1) ? '--nocache' : '');
  my $configFolder = AttrVal($name, 'configFolder', undef);
  my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
  my $today = sprintf('%02d/%02d/%04d', $mon + 1, $mday, $year + 1900);
  my $gcalcliVersion = 3;

  Log3 $name, 5, $name.'_DoRun: start running';

  # prepare input values
  $calendarDays = decode_utf8($calendarDays) if (defined($calendarDays));
  $calFilter = decode_utf8($calFilter) if (defined($calFilter));
  $configFolder = decode_utf8($configFolder) if (defined($configFolder));

  # get version of gcalcli
  ($calData, $result) = ($_ = decode_utf8(qx(export PYTHONIOENCODING=utf8 && gcalcli --version 2>&1)), $? >> 8);

  if (defined($calData) && ($calData =~ /gcalcli v(\d)/))
  {
    $gcalcliVersion = $1;
  }
  else
  {
    Log3 $name, 3, encode_utf8($name.": export PYTHONIOENCODING=utf8 && gcalcli --version");
    Log3 $name, 3, encode_utf8($name.': something went wrong (check your parameters) - '.$calData) if defined($calData);

    $calData = '';
  }

  if (defined($configFolder))
  {
    if ($gcalcliVersion < 4)
    {
      $configFolder = '--configFolder '.$configFolder;
    }
    else
    {
      $configFolder = '--config-folder '.$configFolder;
    }
  }
  else
  {
    $configFolder = '';
  }

  # calendar filter attribute already set?
  if (!defined($calFilter))
  {
    # get list of calendars
    ($calData, $result) = ($_ = decode_utf8(qx(export PYTHONIOENCODING=utf8 && gcalcli list --nocolor $configFolder 2>&1)), $? >> 8);

    if (0 != $result)
    {
      Log3 $name, 3, encode_utf8($name.': export PYTHONIOENCODING=utf8 && gcalcli list --nocolor '.$configFolder);
      Log3 $name, 3, encode_utf8($name.': something went wrong (check your parameters) - '.$calData) if defined($calData);

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
  if ($gcalcliVersion < 4)
  {
    ($calData, $result) = ($_ = decode_utf8(qx(export PYTHONIOENCODING=utf8 && gcalcli agenda $calendarPeriod $configFolder $calFilter --details calendar --details url --details location --details description --details email $noCache --tsv 2>&1)), $? >> 8);
  }
  else
  {
    ($calData, $result) = ($_ = decode_utf8(qx(export PYTHONIOENCODING=utf8 && gcalcli agenda $calendarPeriod $configFolder $calFilter --details calendar --details longurl --details location --details description --details email $noCache --tsv 2>&1)), $? >> 8);
  }

  if (0 != $result)
  {
    if ($gcalcliVersion < 4)
    {
      Log3 $name, 3, encode_utf8($name.": export PYTHONIOENCODING=utf8 && gcalcli agenda $calendarPeriod $configFolder $calFilter --details calendar --details url --details location --details description --details email $noCache --tsv");
    }
    else
    {
      Log3 $name, 3, encode_utf8($name.": export PYTHONIOENCODING=utf8 && gcalcli agenda $calendarPeriod $configFolder $calFilter --details calendar --details longurl --details location --details description --details email $noCache --tsv");
    }
    Log3 $name, 3, encode_utf8($name.': something went wrong (check your parameters) - '.$calData) if defined($calData);

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
    my $invertFilter = AttrVal($name, 'invertFilter', 0);
    my $calendarType = AttrVal($name, 'calendarType', 'standard');
    my $calendarIncludeStarted = AttrVal($name, 'calendarIncludeStarted', undef);
    my %icludeStarted = ();
    my $sourceColor;
    my @sourceColors = split('\s*,\s*' , decode_utf8(AttrVal($name, 'sourceColor', '')));
    my %groups;
    my $lastStartDate;
    my $afternext;


    Log3 $name, 5, $name.': '.$calData;

    # prepare input values
    $filterSummary = decode_utf8($filterSummary) if (defined($filterSummary));
    $filterLocation = decode_utf8($filterLocation) if (defined($filterLocation));
    $filterDescription = decode_utf8($filterDescription) if (defined($filterDescription));
    $filterSource = decode_utf8($filterSource) if (defined($filterSource));
    $filterAuthor = decode_utf8($filterAuthor) if (defined($filterAuthor));
    $filterOverall = decode_utf8($filterOverall) if (defined($filterOverall));
    $calendarType = decode_utf8($calendarType) if (defined($calendarType));
    $calendarIncludeStarted = decode_utf8($calendarIncludeStarted) if (defined($calendarIncludeStarted));

    %icludeStarted = map { $_ => 1 } split(/\s*,\s*/, $calendarIncludeStarted) if (defined($calendarIncludeStarted));

    foreach $_ (@entry)
    {
      # split each line by tabs
      @_ = split("\t", $_);

      # bugfix: tabulator is not replaced by anything else which leads to an invalid format (try to fix it)
      if (scalar(@_) > 11)
      {
        # merge all additional fields into the description
        splice(@_, 8, scalar(@_) - 10, join(' ', @_[8..(scalar(@_) - 3)]));
      }

      # output must have exactly 11 fields of data
      if (11 == scalar(@_))
      {
        my ($startYear, $startMonth, $startDay) = split("-", $_[0]);
        my ($startHour, $startMin) = split(":", $_[1]);
        my $startDate = fhemTimeLocal(0, $startMin, $startHour, $startDay, $startMonth - 1, $startYear - 1900);

        # apply some content filters
        if (0 == $invertFilter)
        {
          next if ((defined($filterSummary) && ($_[6] =~ /$filterSummary/)) ||
                   (defined($filterLocation) && ($_[7] =~ /$filterLocation/)) ||
                   (defined($filterDescription) && ($_[8] =~ /$filterDescription/)) ||
                   (defined($filterSource) && ($_[9] =~ /$filterSource/)) ||
                   (defined($filterAuthor) && ($_[10] =~ /$filterAuthor/)) ||
                   (defined($filterOverall) && (($_[6] =~ /$filterOverall/) ||
                                                ($_[7] =~ /$filterOverall/) ||
                                                ($_[8] =~ /$filterOverall/) ||
                                                ($_[9] =~ /$filterOverall/) ||
                                                ($_[10] =~ /$filterOverall/))) ||
                   (!exists($icludeStarted{$_[9]}) && ($startDate <= time)));
        }
        else
        {
          next if (defined($filterSummary) && ($_[6] !~ /$filterSummary/));
          next if (defined($filterLocation) && ($_[7] !~ /$filterLocation/));
          next if (defined($filterDescription) && ($_[8] !~ /$filterDescription/));
          next if (defined($filterSource) && ($_[9] !~ /$filterSource/));
          next if (defined($filterAuthor) && ($_[10] !~ /$filterAuthor/));
          next if (defined($filterOverall) && (($_[6] !~ /$filterOverall/) &&
                                               ($_[7] !~ /$filterOverall/) &&
                                               ($_[8] !~ /$filterOverall/) &&
                                               ($_[9] !~ /$filterOverall/) &&
                                               ($_[10] !~ /$filterOverall/)));

          next if (!exists($icludeStarted{$_[9]}) && ($startDate <= time));
        }

        # eliminate events with the same summary if type waste is active
        $afternext = '';
        if ('waste' eq $calendarType)
        {
          #Log3 $name, 5, $name.': '.join(', ', @_);

          if (!exists($groups{$_[6]}))
          {
            $groups{$_[6]} = 1;
          }
          elsif (1 == $groups{$_[6]})
          {
            my $data;

            #Log3 $name, 3, $name.': afternext '.$_[6].' ('.$_[0].')';

            # replace afternext if needed
            foreach $data (@calStruct)
            {
              if (@$data[6] eq $_[6])
              {
                @$data[12] = $_[0];
              }
            }

            $groups{$_[6]} = 2;

            next;
          }
          else
          {
            next;
          }
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
        push(@_, $afternext);
        push(@calStruct, [@_]);
      }
      else
      {
        Log3 $name, 3, $name.': something went wrong (invalid gcalcli output) - '.join(', ', @_);
      }
    }

    # encode filtered calendar entries
    $calData = eval {encode_base64(freeze(\@calStruct), '')};

    if ($@)
    {
      Log3 $name, 3, $name.': encode of calendar data failed: '.$@;
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
  my ($name, $calList, $calDataEnc) = split("\\|", $string);
  my $hash = $defs{$name};
  my @calData = ();
  my $cterm_new = 0;
  my $ctoday_new = 0;
  my $ctomorrow_new = 0;
  my $calendarType = AttrVal($name, 'calendarType', 'standard');
  my $daysUntilNext = 0;

  Log3 $name, 5, $name.'_DoEnd: end running';

  # prepare input values
  $calendarType = decode_utf8($calendarType) if (defined($calendarType));

  # decode results
  $calList = decode_base64($calList);
  @calData = eval {@{thaw(decode_base64($calDataEnc))} if ('' ne $calDataEnc)};

  if ($@)
  {
    Log3 $name, 3, $name.': decode of calendar data failed: '.$@;
  }

  if ('' ne $calList)
  {
    $calList =~ s/\s/#/g;
    addToDevAttrList($name, encode_utf8('calendarFilter:multiple-strict,'.$calList));
    addToDevAttrList($name, encode_utf8('calendarIncludeStarted:multiple-strict,'.$calList));
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
    my $emptyReadingText = AttrVal($name, 'emptyReadingText', '');
    my $alldayText = AttrVal($name, 'alldayText', 'all-day');
    my $daysLeftLongText = AttrVal($name, 'daysLeftLongText', 'today,tomorrow,in % days');
    my @daysLeftLongArr;
    my $wasteEventSeparator = AttrVal($name, 'wasteEventSeparator', 'and');
    my @readingPrefix = ('standard' eq $calendarType) ? ('t_', 'today_', 'tomorrow_') : ((1 == AttrVal($name, 'readingPrefix', 0)) ? ($name.'_') : (''));
    my $showAge = AttrVal($name, 'showAge', 0);
    my $ageSource = AttrVal($name, 'ageSource', 'description');
    my $nowText = undef;
    my $nowDescription = '';
    my $nextDate = undef;
    my $nextText = '';
    my $nextDescription = '';
    my %umlaute = ("ä" => "ae", "Ä" => "Ae", "ü" => "ue", "Ü" => "Ue", "ö" => "oe", "Ö" => "Oe", "ß" => "ss");

    # prepare input values
    $weekDayArr = decode_utf8($weekDayArr) if (defined($weekDayArr));
    $emptyReadingText = decode_utf8($emptyReadingText) if (defined($emptyReadingText));
    $alldayText = decode_utf8($alldayText) if (defined($alldayText));
    $daysLeftLongText = decode_utf8($daysLeftLongText) if (defined($daysLeftLongText));
    @daysLeftLongArr = split('\s*,\s*', $daysLeftLongText);
    $wasteEventSeparator = ' '.decode_utf8($wasteEventSeparator).' ' if (defined($wasteEventSeparator));
    $ageSource = decode_utf8($ageSource) if (defined($ageSource));

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
      # 12 = afternext

      my $startDate = @$_[0];
      my $startTime = @$_[1];
      my $endDate = ('' ne @$_[2] ? @$_[2] : @$_[0]);
      my $endTime = ('' ne @$_[3] ? @$_[3] : @$_[1]);
      my $url = ('' ne @$_[4] ? @$_[4] : $emptyReadingText);
      my $summary = ('' ne @$_[6] ? @$_[6] : $emptyReadingText);
      my $location = ('' ne @$_[7] ? @$_[7] : $emptyReadingText);
      my $description = ('' ne @$_[8] ? @$_[8] : $emptyReadingText);
      my $calendar = ('' ne @$_[9] ? @$_[9] : $emptyReadingText);
      my $author = ('' ne @$_[10] ? @$_[10] : $emptyReadingText);
      my $sourceColor = ('' ne @$_[11] ? @$_[11] : $emptyReadingText);
      my $afternext = @$_[12];
      my ($startYear, $startMonth, $startDay) = split("-", $startDate);
      my ($endYear, $endMonth, $endDay) = split("-", $endDate);
      my $eventDate = fhemTimeLocal(0, 0, 0, $startDay, $startMonth - 1, $startYear - 1900);
      my $daysleft = floor(($eventDate - time) / 60 / 60 / 24 + 1);
      my $daysleftLong;
      my $daysleftNext;
      my $startDateStr = $startDay.'.'.$startMonth.'.'.$startYear;
      my $endDateStr = $endDay.'.'.$endMonth.'.'.$endYear;
      my $timeShort;
      my $weekdayStr;

      # calculate days to next event
      if ('' ne $afternext)
      {
        my ($y, $m, $d) = split("-", $afternext);
        my $ed = fhemTimeLocal(0, 0, 0, $d, $m - 1, $y - 1900);
        $daysleftNext = floor(($ed - time) / 60 / 60 / 24 + 1);
        #Log3 $name, 3, $name.': days afternext '.$daysleftNext;
      }

      # fix that event is visible if endtime is 0:00
      #if (($daysleft < 0) && ($endTime eq "00:00"))
      #{
      #  next if (($daysleft < 0) && ($endTime eq "00:00") &&
      #           (0 == (fhemTimeLocal(0, 0, 0, $endDay, $endMonth - 1, $endYear - 1900) - time)));
      #}

      # fix daysleft if event is already running
      $daysleft = 0 if ($daysleft < 0);

      # generate string daysleft
      if (0 == $daysleft)
      {
        $daysleftLong = $daysLeftLongArr[0];
      }
      elsif (1 == $daysleft)
      {
        $daysleftLong = $daysLeftLongArr[1];
      }
      else
      {
        $daysleftLong = $daysLeftLongArr[2];
        $daysleftLong =~ s/%/$daysleft/;
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
            my $readingName = $summary;
            $readingName =~ s/ /_/g;
            $readingName =~ s/([äÄüÜöÖß])/$umlaute{$1}/eg;
            $readingName =~ tr/a-zA-Z0-9\-_//dc;

            #Log3 $name, 3, $name.': '.$summary.' days afternext '.$daysleftNext;

            readingsBulkUpdate($hash, encode_utf8($readingPrefix[$i].$readingName.'_date'), encode_utf8($startDateStr));
            readingsBulkUpdate($hash, encode_utf8($readingPrefix[$i].$readingName.'_days'), encode_utf8($daysleft));
            readingsBulkUpdate($hash, encode_utf8($readingPrefix[$i].$readingName.'_daysnext'), encode_utf8($daysleftNext)) if (defined($daysleftNext));
            readingsBulkUpdate($hash, encode_utf8($readingPrefix[$i].$readingName.'_location'), encode_utf8($location));
            readingsBulkUpdate($hash, encode_utf8($readingPrefix[$i].$readingName.'_description'), encode_utf8($description));
            readingsBulkUpdate($hash, encode_utf8($readingPrefix[$i].$readingName.'_text'), encode_utf8($summary));
            readingsBulkUpdate($hash, encode_utf8($readingPrefix[$i].$readingName.'_weekday'), encode_utf8($weekdayStr));
            readingsBulkUpdate($hash, encode_utf8($readingPrefix[$i].$readingName.'_url'), encode_utf8('<html><a href="'.$url.'" target="_blank">link</a></html>'));

            if (0 == $daysleft)
            {
              if (defined($nowText))
              {
                $nowText .= $wasteEventSeparator.$summary;
                $nowDescription .= $wasteEventSeparator.$description if ($nowDescription ne $description);

                readingsBulkUpdate($hash, 'now_text', encode_utf8($nowText));
                readingsBulkUpdate($hash, 'now_description', encode_utf8($nowDescription));
              }
              else
              {
                readingsBulkUpdate($hash, 'now_date', encode_utf8($startDateStr));
                readingsBulkUpdate($hash, 'now_daysnext', encode_utf8($daysleftNext)) if (defined($daysleftNext));
                readingsBulkUpdate($hash, 'now_location', encode_utf8($location));
                readingsBulkUpdate($hash, 'now_description', encode_utf8($description));
                readingsBulkUpdate($hash, 'now_text', encode_utf8($summary));
                readingsBulkUpdate($hash, 'now_weekday', encode_utf8($weekdayStr));
                readingsBulkUpdate($hash, 'now_url', encode_utf8('<html><a href="'.$url.'" target="_blank">link</a></html>'));

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

                readingsBulkUpdate($hash, 'next_text', encode_utf8($nextText));
                readingsBulkUpdate($hash, 'next_description', encode_utf8($nextDescription));
              }
            }
            elsif ($daysleft > 0)
            {
              readingsBulkUpdate($hash, 'next_date', encode_utf8($startDateStr));
              readingsBulkUpdate($hash, 'next_days', encode_utf8($daysleft));
              readingsBulkUpdate($hash, 'next_daysnext', encode_utf8($daysleftNext)) if (defined($daysleftNext));
              readingsBulkUpdate($hash, 'next_location', encode_utf8($location));
              readingsBulkUpdate($hash, 'next_description', encode_utf8($description));
              readingsBulkUpdate($hash, 'next_text', encode_utf8($summary));
              readingsBulkUpdate($hash, 'next_weekday', encode_utf8($weekdayStr));
              readingsBulkUpdate($hash, 'next_url', encode_utf8('<html><a href="'.$url.'" target="_blank">link</a></html>'));

              $nextDate = $startDateStr;
              $nextText = $summary;
              $nextDescription = $description;
              $daysUntilNext = $daysleft;
            }
          }
          else
          {
            my $age = -1;

            if ($showAge)
            {
              if ((('description' eq $ageSource) && ($description =~ /((?:19|20|21)\d{2})/)) ||
                  (('summary' eq $ageSource) && ($summary =~ /((?:19|20|21)\d{2})/)) ||
                  (('location' eq $ageSource) && ($location =~ /((?:19|20|21)\d{2})/)))
              {
                $age = $startYear - $1;
              }
            }

            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_bdate', encode_utf8($startDateStr));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_btime', encode_utf8($startTime));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_daysleft', encode_utf8($daysleft));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_daysleftLong', encode_utf8($daysleftLong));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_edate', encode_utf8($endDateStr));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_etime', encode_utf8($endTime));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_location', encode_utf8($location));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_description', encode_utf8($description));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_author', encode_utf8($author));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_source', encode_utf8($calendar));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_sourcecolor', encode_utf8($sourceColor));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_summary', encode_utf8($summary));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_timeshort', encode_utf8($timeShort));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_weekday', encode_utf8($weekdayStr));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_age', encode_utf8($age)) if ($showAge && ($age >= 0));
            readingsBulkUpdate($hash, $readingPrefix[$i].('0' x $counterLength).($$counter + 1).'_url', encode_utf8('<html><a href="'.$url.'" target="_blank">link</a></html>'));
          }

          $$counter++;
        }
      }

      last if ($cterm_new >= AttrVal($name, 'maxEntries', 200));
    }
  }

  if ('waste' eq $calendarType)
  {
    readingsBulkUpdate($hash, 'state', encode_utf8($daysUntilNext));
  }
  else
  {
    readingsBulkUpdate($hash, 'c-term', encode_utf8($cterm_new));
    readingsBulkUpdate($hash, 'c-today', encode_utf8($ctoday_new));
    readingsBulkUpdate($hash, 'c-tomorrow', encode_utf8($ctomorrow_new));
    readingsBulkUpdate($hash, 'state', encode_utf8('t: '.$cterm_new.' td: '.$ctoday_new.' tm: '.$ctomorrow_new));
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
    <code>sudo pip3 install gcalcli</code><br><br>
    <code>sudo -u fhem gcalcli list --noauth_local_webserver</code><br>
    or<br>
    <code>sudo -u fhem gcalcli --noauth_local_webserver list</code><br><br>
    Copy the URL into a browser and start it. Accept the connection to your Google Calendar and copy the OAuth token. Enter the token in your fhem console window and press enter.<br><br>
    <code>sudo -u fhem gcalcli list</code><br><br>
    Check if you can get a list of you calendars now and proceed if it was successful.<br>
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
    <code>define &lt;name&gt; GCALVIEW &lt;timeout in seconds&gt;</code>
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
    <li><b>calendarIncludeStarted:</b> show already started appointments of today (default: already started appointments are disabled for all calendars)<br></li>
    <li><b>maxEntries:</b> limit the maximum appointments (not more than 200 allowed)<br></li>
    <li><b>disable:</b> disable the module (no update anymore)<br></li>
    <li><b>cache:</b> disable the caching of calendar requests (default: cache activated)<br></li>
    <li><b>filterSummary:</b> regex to filter a summary (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>filterLocation:</b> regex to filter a location (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>filterDescription:</b> regex to filter a description (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>filterSource:</b> regex to filter a source (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>filterAuthor:</b> regex to filter an author (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>filterOverall:</b> regex to filter a summary, location, description, source or author (whole appointment will be removed from output if the regex matches)<br></li>
    <li><b>invertFilter:</b> enable/disable invertion of filter which means that everything that does not match the regular expression is filtered out. (default: disabled)<br></li>
    <li><b>alldayText:</b> set the text for an allday event (default: all-day)<br></li>
    <li><b>emptyReadingText:</b> set the text for empty readings (default: no text)<br></li>
    <li><b>weekdayText:</b> set the weekday text as comma separated list (default: Monday,Tuesday,Wednesday,Thursday,Friday,Saturday,Sunday)<br></li>
    <li><b>daysLeftLongText:</b> set the daysLeftLong text as comma separated list. % in part 3 is replaced by the number of days. (default: today,tomorrow,in % days)<br></li>
    <li><b>readingPrefix:</b> calendar name is used as reading prefix if type waste is active<br></li>
    <li><b>sourceColor:</b> set a color string based on source (Format: source:color,source:color,...)<br></li>
    <li><b>wasteEventSeparator:</b> separator for waste events if there are more than 1 event in one day<br></li>
    <li><b>showAge:</b> try to find the year of birth within the field defined by ageSource (year must have 4 digits) and to calculate the age of a person.<br></li>
    <li><b>ageSource:</b> defines the location of the year of birth and can be the description, the summary or the location (default: description).<br></li>
    <li><b>configFolder:</b> path to authorization data of gcalcli (can only be used if the authorization procedure was done with the same --configFolder &lt;path&gt; parameter!)<br></li>
    <br>
  </ul>
</ul>

=end html
=cut
