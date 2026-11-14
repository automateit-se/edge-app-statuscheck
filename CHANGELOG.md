# Changelog

## Unreleased

## 0.1.0

- First version. A check function of type `button`: `1` runs it, from the dashboard, a KNX button or anything else;
  its value is the number of deviations and its `msg` what they were.
- Items chosen with the function selector, each with when it deviates (open or on, closed or off, above, below or
  equal to a value), a text and a sound. The sounds of the deviations are played one after another, or the ok
  sound when there is none; unknown status is told, never taken as ok. Optional notification with the texts.
- Settings kept in step with the metadata both ways, last change wins: the items on their functions, the check's
  own settings on the check function.
