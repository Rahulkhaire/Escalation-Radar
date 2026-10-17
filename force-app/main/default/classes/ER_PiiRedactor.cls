/**
 * Best-effort redaction of obvious personal data before text leaves Salesforce.
 * This is data minimisation, not a guarantee: free text can contain names or other
 * identifiers that regular expressions cannot detect. See docs/SECURITY.md.
 */
public with sharing class ER_PiiRedactor {
    private static final Pattern EMAIL = Pattern.compile('[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}');
    private static final Pattern CARD = Pattern.compile('\\b(?:\\d[ \\-]?){13,19}\\b');
    private static final Pattern SSN = Pattern.compile('\\b\\d{3}-\\d{2}-\\d{4}\\b');
    private static final Pattern PHONE = Pattern.compile('(?<!\\d)(?:\\+?\\d{1,3}[\\s.\\-]?)?(?:\\(?\\d{3}\\)?[\\s.\\-]?)\\d{3}[\\s.\\-]?\\d{4}(?!\\d)');
    private static final Pattern URL_PAT = Pattern.compile('https?://\\S+');

    public static String redact(String input) {
        if (String.isBlank(input)) {
            return input;
        }
        String s = input;
        s = EMAIL.matcher(s).replaceAll('[EMAIL]');
        s = SSN.matcher(s).replaceAll('[ID]');
        s = CARD.matcher(s).replaceAll('[NUMBER]');
        s = PHONE.matcher(s).replaceAll('[PHONE]');
        s = URL_PAT.matcher(s).replaceAll('[URL]');
        return s;
    }

    /** Redacts, strips control characters and truncates untrusted text to a safe length. */
    public static String sanitize(String input, Integer maxChars) {
        if (input == null) {
            return '';
        }
        String s = redact(input).replaceAll('[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]', ' ');
        s = s.replace('<', '(').replace('>', ')');
        return s.length() <= maxChars ? s : s.substring(0, maxChars);
    }
}
