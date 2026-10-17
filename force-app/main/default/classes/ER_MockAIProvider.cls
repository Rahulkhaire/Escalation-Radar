/**
 * Deterministic offline AI provider for demos and tests. It inspects keywords in the already
 * sanitised text, so results are reproducible without any external service or credentials.
 */
public with sharing class ER_MockAIProvider implements ER_AIProvider {
    public String name() {
        return 'MOCK';
    }

    public ER_AIAnalysis analyze(ER_AIRequest req) {
        String text = ((req.subject == null ? '' : req.subject) + ' ' + (req.description == null ? '' : req.description) + ' ' +
            String.join(req.recentComments, ' ')).toLowerCase();
        ER_AIAnalysis a = new ER_AIAnalysis();
        a.provider = name();
        Boolean angry = containsAny(text, new List<String>{ 'unacceptable', 'cancel', 'frustrat', 'escalate', 'legal', 'angry', 'again' });
        Boolean outage = containsAny(text, new List<String>{ 'outage', 'down', 'cannot log', 'unavailable', 'production' });
        a.urgency = (outage || angry) ? 'HIGH' : (req.deterministicScore >= 50 ? 'MEDIUM' : 'LOW');
        a.sentiment = angry ? 'NEGATIVE' : 'NEUTRAL';
        String subj = String.isBlank(req.subject) ? 'the reported issue' : req.subject;
        a.summary = 'Customer reports: ' + subj + '. Current deterministic risk is ' + req.riskCategory + ' (' + req.deterministicScore + '/100).';
        a.riskExplanation = 'Mock analysis. ' + (req.factorSummary == null ? '' : req.factorSummary);
        if (outage) {
            a.rootCauses.add('PERFORMANCE');
        }
        if (containsAny(text, new List<String>{ 'integration', 'api', 'sync' })) {
            a.rootCauses.add('INTEGRATION');
        }
        if (a.rootCauses.isEmpty()) {
            a.rootCauses.add('OTHER');
        }
        a.nextSteps.add('Review the Case with the owner and confirm the next customer update time.');
        if (outage) {
            a.nextSteps.add('Check for related incidents before responding.');
        }
        a.suggestedCustomerUpdate = 'Thank you for your patience. We are actively working on your case and will share a further update shortly.';
        a.confidence = 0.60;
        a.proposedActions.add(ER_Constants.ACT_DRAFT);
        if (a.urgency == 'HIGH') {
            a.proposedActions.add(ER_Constants.ACT_REVIEW);
        }
        return a;
    }

    private static Boolean containsAny(String text, List<String> needles) {
        for (String n : needles) {
            if (text.contains(n)) {
                return true;
            }
        }
        return false;
    }
}
