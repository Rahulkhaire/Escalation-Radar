/**
 * Strict schema validation of model output. Anything outside the schema is rejected or dropped:
 * enums are checked, lengths are capped, root causes and actions are intersected with allowlists.
 * Free text is treated as display data only and is never executed or interpreted as instructions.
 */
public with sharing class ER_AIResponseValidator {
    public static final Set<String> URGENCY = new Set<String>{ 'LOW', 'MEDIUM', 'HIGH' };
    public static final Set<String> SENTIMENT = new Set<String>{ 'NEGATIVE', 'NEUTRAL', 'POSITIVE', 'UNKNOWN' };
    public static final Set<String> ROOT_CAUSES = new Set<String>{
        'PRODUCT_DEFECT', 'CONFIGURATION', 'INTEGRATION', 'PERFORMANCE', 'DATA_QUALITY',
        'ACCESS_PERMISSIONS', 'TRAINING', 'BILLING', 'OTHER'
    };

    public static ER_AIAnalysis parse(String raw, String providerName) {
        if (String.isBlank(raw)) {
            throw new ER_AIValidationException('AI response was empty.');
        }
        String json = stripFences(raw.trim());
        Object parsed;
        try {
            parsed = System.JSON.deserializeUntyped(json);
        } catch (Exception e) {
            throw new ER_AIValidationException('AI response was not valid JSON.');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw new ER_AIValidationException('AI response must be a JSON object.');
        }
        Map<String, Object> m = (Map<String, Object>) parsed;
        ER_AIAnalysis a = new ER_AIAnalysis();
        a.provider = providerName;
        a.summary = requiredText(m, 'summary', 600);
        a.riskExplanation = requiredText(m, 'risk_explanation', 800);
        a.urgency = requiredEnum(m, 'urgency', URGENCY);
        a.sentiment = requiredEnum(m, 'sentiment', SENTIMENT);
        a.suggestedCustomerUpdate = optionalText(m, 'suggested_customer_update', 1200);
        a.confidence = optionalConfidence(m.get('confidence'));
        for (String rc : stringList(m.get('root_causes'), 5)) {
            String up = rc.toUpperCase();
            if (ROOT_CAUSES.contains(up) && !a.rootCauses.contains(up)) {
                a.rootCauses.add(up);
            }
        }
        for (String ns : stringList(m.get('next_steps'), 5)) {
            a.nextSteps.add(cap(ns, 300));
        }
        for (String act : stringList(m.get('proposed_actions'), 6)) {
            String up = act.toUpperCase();
            // Unknown identifiers are dropped, never executed.
            if (ER_Constants.ALLOWED_ACTIONS.contains(up) && !a.proposedActions.contains(up)) {
                a.proposedActions.add(up);
            }
        }
        return a;
    }

    private static String stripFences(String s) {
        if (s.startsWith('```')) {
            Integer nl = s.indexOf('\n');
            s = nl >= 0 ? s.substring(nl + 1) : s;
            if (s.endsWith('```')) {
                s = s.substring(0, s.length() - 3);
            }
        }
        return s.trim();
    }

    private static String requiredText(Map<String, Object> m, String key, Integer max) {
        Object v = m.get(key);
        if (!(v instanceof String) || String.isBlank((String) v)) {
            throw new ER_AIValidationException('AI response is missing required field: ' + key);
        }
        return cap((String) v, max);
    }

    private static String optionalText(Map<String, Object> m, String key, Integer max) {
        Object v = m.get(key);
        return v instanceof String ? cap((String) v, max) : null;
    }

    private static String requiredEnum(Map<String, Object> m, String key, Set<String> allowed) {
        Object v = m.get(key);
        if (!(v instanceof String) || !allowed.contains(((String) v).toUpperCase())) {
            throw new ER_AIValidationException('AI response has an invalid value for: ' + key);
        }
        return ((String) v).toUpperCase();
    }

    private static Decimal optionalConfidence(Object v) {
        if (v == null) {
            return null;
        }
        if (!(v instanceof Decimal) && !(v instanceof Integer) && !(v instanceof Double)) {
            throw new ER_AIValidationException('AI confidence must be a number.');
        }
        Decimal d = Decimal.valueOf(String.valueOf(v));
        if (d < 0 || d > 1) {
            throw new ER_AIValidationException('AI confidence must be between 0 and 1.');
        }
        return d.setScale(2, RoundingMode.HALF_UP);
    }

    private static List<String> stringList(Object v, Integer maxItems) {
        List<String> out = new List<String>();
        if (!(v instanceof List<Object>)) {
            return out;
        }
        for (Object o : (List<Object>) v) {
            if (o instanceof String && out.size() < maxItems && String.isNotBlank((String) o)) {
                out.add(((String) o).trim());
            }
        }
        return out;
    }

    private static String cap(String s, Integer max) {
        return s.length() <= max ? s : s.substring(0, max);
    }
}
