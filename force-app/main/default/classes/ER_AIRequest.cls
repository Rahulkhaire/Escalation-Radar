/** Minimised, sanitised input for an AI provider. Never contains customer names or contact details. */
public with sharing class ER_AIRequest {
    public Id caseId;
    public String correlationId;
    public String priority;
    public String accountTier;
    public Decimal deterministicScore;
    public String riskCategory;
    public String factorSummary;
    public String subject;
    public String description;
    public List<String> recentComments = new List<String>();
}
