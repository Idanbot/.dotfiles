# Shared duration formatting for JSON performance artifacts.

def pad2:
  tostring | if length == 1 then "0" + . else . end;

def pad3:
  tostring |
  if length == 1 then "00" + .
  elif length == 2 then "0" + .
  else .
  end;

def duration_seconds:
  if . == null then null else . / 1000 end;

def duration_human:
  if . == null then
    "n/a"
  else
    . as $raw |
    (if $raw < 0 then "-" else "" end) as $sign |
    (if $raw < 0 then -$raw else $raw end) as $absolute |
    ($absolute | round) as $rounded |
    ($rounded / 60000 | floor) as $minutes |
    ($rounded % 60000) as $remaining |
    ($remaining / 1000 | floor) as $seconds |
    ($rounded % 1000) as $milliseconds |
    ($rounded / 1000 | floor) as $whole_seconds |
    if $minutes > 0 then
      ($sign + ($minutes | tostring) + "m " +
        ($seconds | pad2) + "." + ($milliseconds | pad3) + "s (" +
        $sign + ($whole_seconds | tostring) + "." +
        ($milliseconds | pad3) + " s / " + $sign +
        ($rounded | tostring) + " ms)")
    elif $rounded >= 1000 then
      ($sign + ($whole_seconds | tostring) + "." +
        ($milliseconds | pad3) + " s (" + $sign +
        ($rounded | tostring) + " ms)")
    else
      ($sign + ($rounded | tostring) + " ms (" + $sign +
        "0." + ($milliseconds | pad3) + " s)")
    end
  end;
