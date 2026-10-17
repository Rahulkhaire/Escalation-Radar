/** Validated, typed AI analysis result. Only produced by ER_AIResponseValidator or a mock provider. */
public with sharing class ER_AIAnalysis {
    public String summary;
    public String riskExplanation;
    public String urgency;
    public String sentiment;
    public List<String> rootCauses = new List<String>();
    public List<String> nextSteps = new List<String>();
    public String suggestedCustomerUpdate;
    public Decimal confidence;
    public List<String> proposedActions = new List<String>();
    public String provider;
}
