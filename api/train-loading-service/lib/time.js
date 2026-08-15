const UK_TIME_ZONE = "Europe/London";

const formatter = new Intl.DateTimeFormat("en-GB", {
  timeZone: UK_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

export function ukDateParts(date) {
  return Object.fromEntries(formatter.formatToParts(date).map((part) => [part.type, part.value]));
}

export function ukClockTime(value) {
  if (!value) return null;
  const string = String(value);
  const clockOnly = string.match(/^(\d{2}):(\d{2})/);
  if (clockOnly) return `${clockOnly[1]}:${clockOnly[2]}`;

  // Staff LDB timestamps have no offset and already represent UK railway time.
  const localTimestamp = string.match(/^\d{4}-\d{2}-\d{2}T(\d{2}):(\d{2})(?::\d{2}(?:\.\d+)?)?$/);
  if (localTimestamp) return `${localTimestamp[1]}:${localTimestamp[2]}`;

  const date = new Date(string);
  if (Number.isNaN(date.getTime())) return null;
  const parts = ukDateParts(date);
  return `${parts.hour}:${parts.minute}`;
}
