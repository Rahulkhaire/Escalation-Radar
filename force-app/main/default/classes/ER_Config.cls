/**
 * Reads risk rules and integration settings from Custom Metadata Types.
 * Only non-secret configuration lives here. The fallback values below apply solely
 * when the ER_Risk_Config__mdt "Default" record is missing, and are documented in docs/DATA_MODEL.md.
 */
public with sharing class ER_Config {
    public class RiskConfig {
        public String version = '1.0.0-fallback';
        public Decimal wSla = 35;
        public Decimal wPriority = 20;
        public Decimal wReopen = 15;
        public Decimal wTier = 15;
        public Decimal wAgeComms = 15;
        public Decimal tMedium = 25;
        public Decimal tHigh = 50;
        public Decimal tCritical = 75;
        public Decimal slaRampStartPct = 50;
        public Decimal slaHoursHigh = 8;
        public Decimal slaHoursMedium = 24;
        public Decimal slaHoursLow = 72;
        public Boolean slaUseBusinessHours = false;
        public Decimal ageCapHours = 72;
        public Decimal staleUpdateHours = 24;
        public Integer reopenCap = 3;
        public Set<String> approvalRequired = new Set<String>();
        public Map<String, Decimal> priorityFractions = new Map<String, Decimal>();
        public Map<String, Decimal> tierFractions = new Map<String, Decimal>();

        public Decimal weightTotal() {
            return wSla + wPriority + wReopen + wTier + wAgeComms;
        }
    }

    public class IntegrationSetting {
        public Boolean enabled = false;
        public String provider = 'NONE';
        public String namedCredential;
        public String endpointPath = '';
        public String model;
        public Integer timeoutMs = 20000;
        public Integer maxPayloadChars = 6000;
        public Integer maxTokens = 800;
        public Integer maxRetries = 3;
        public Decimal minScore = 40;
        public String minCategory = 'HIGH';
        public Decimal maxUplift = 5;
        public String reassignQueue;
        public String escalationFlow;
    }

    @TestVisible
    private static RiskConfig riskOverride;
    @TestVisible
    private static Map<String, IntegrationSetting> settingOverrides = new Map<String, IntegrationSetting>();
    private static RiskConfig riskCache;

    @TestVisible
    private static void setRiskOverride(RiskConfig cfg) {
        riskOverride = cfg;
    }

    @TestVisible
    private static void setSettingOverride(String name, IntegrationSetting s) {
        settingOverrides.put(name, s);
    }

    @TestVisible
    private static void resetOverrides() {
        riskOverride = null;
        riskCache = null;
        settingOverrides = new Map<String, IntegrationSetting>();
    }

    public static RiskConfig getRiskConfig() {
        if (riskOverride != null) {
            return riskOverride;
        }
        if (riskCache != null) {
            return riskCache;
        }
        RiskConfig c = new RiskConfig();
        c.priorityFractions = new Map<String, Decimal>{ 'High' => 1.0, 'Medium' => 0.5, 'Low' => 0.2 };
        c.tierFractions = new Map<String, Decimal>{ 'Strategic' => 1.0, 'Enterprise' => 0.75, 'Standard' => 0.4, 'Basic' => 0.1 };
        ER_Risk_Config__mdt m = ER_Risk_Config__mdt.getInstance('Default');
        if (m != null) {
            c.version = String.isBlank(m.Version__c) ? c.version : m.Version__c;
            c.wSla = nz(m.Weight_SLA__c, c.wSla);
            c.wPriority = nz(m.Weight_Priority__c, c.wPriority);
            c.wReopen = nz(m.Weight_Reopen__c, c.wReopen);
            c.wTier = nz(m.Weight_Account_Tier__c, c.wTier);
            c.wAgeComms = nz(m.Weight_Age_Comms__c, c.wAgeComms);
            c.tMedium = nz(m.Threshold_Medium__c, c.tMedium);
            c.tHigh = nz(m.Threshold_High__c, c.tHigh);
            c.tCritical = nz(m.Threshold_Critical__c, c.tCritical);
            c.slaRampStartPct = nz(m.SLA_Ramp_Start_Pct__c, c.slaRampStartPct);
            c.slaHoursHigh = nz(m.SLA_Hours_High__c, c.slaHoursHigh);
            c.slaHoursMedium = nz(m.SLA_Hours_Medium__c, c.slaHoursMedium);
            c.slaHoursLow = nz(m.SLA_Hours_Low__c, c.slaHoursLow);
            c.slaUseBusinessHours = m.SLA_Use_Business_Hours__c == true;
            c.ageCapHours = nz(m.Age_Cap_Hours__c, c.ageCapHours);
            c.staleUpdateHours = nz(m.Stale_Update_Hours__c, c.staleUpdateHours);
            c.reopenCap = nz(m.Reopen_Cap__c, c.reopenCap).intValue();
            if (String.isNotBlank(m.Approval_Required_Actions__c)) {
                for (String a : m.Approval_Required_Actions__c.split(',')) {
                    if (String.isNotBlank(a)) {
                        c.approvalRequired.add(a.trim().toUpperCase());
                    }
                }
            }
        }
        for (ER_Risk_Factor_Map__mdt f : ER_Risk_Factor_Map__mdt.getAll().values()) {
            if (f.Fraction__c == null || String.isBlank(f.Key__c)) {
                continue;
            }
            if (f.Factor__c == 'Priority') {
                c.priorityFractions.put(f.Key__c, f.Fraction__c);
            } else if (f.Factor__c == 'AccountTier') {
                c.tierFractions.put(f.Key__c, f.Fraction__c);
            }
        }
        riskCache = c;
        return c;
    }

    public static IntegrationSetting getSetting(String developerName) {
        if (settingOverrides.containsKey(developerName)) {
            return settingOverrides.get(developerName);
        }
        IntegrationSetting s = new IntegrationSetting();
        ER_Integration_Setting__mdt m = ER_Integration_Setting__mdt.getInstance(developerName);
        if (m == null) {
            return s;
        }
        s.enabled = m.Enabled__c == true;
        s.provider = String.isBlank(m.Provider__c) ? s.provider : m.Provider__c.toUpperCase();
        s.namedCredential = m.Named_Credential__c;
        s.endpointPath = m.Endpoint_Path__c == null ? '' : m.Endpoint_Path__c;
        s.model = m.Model__c;
        s.timeoutMs = nz(m.Timeout_Ms__c, s.timeoutMs).intValue();
        s.maxPayloadChars = nz(m.Max_Payload_Chars__c, s.maxPayloadChars).intValue();
        s.maxTokens = nz(m.Max_Tokens__c, s.maxTokens).intValue();
        s.maxRetries = nz(m.Max_Retries__c, s.maxRetries).intValue();
        s.minScore = nz(m.Min_Score__c, s.minScore);
        s.minCategory = String.isBlank(m.Min_Category__c) ? s.minCategory : m.Min_Category__c.toUpperCase();
        s.maxUplift = nz(m.Max_Uplift__c, s.maxUplift);
        s.reassignQueue = m.Reassign_Queue__c;
        s.escalationFlow = m.Escalation_Flow__c;
        return s;
    }

    public static IntegrationSetting ai() {
        return getSetting('AI');
    }

    public static IntegrationSetting slack() {
        return getSetting('Slack');
    }

    public static IntegrationSetting actions() {
        return getSetting('Actions');
    }

    /** AI analysis is active when the AI setting is enabled and the provider is MOCK or LLM. */
    public static Boolean aiActive() {
        IntegrationSetting s = ai();
        return s.enabled && (s.provider == 'MOCK' || s.provider == 'LLM');
    }

    private static Decimal nz(Decimal value, Decimal fallback) {
        return value == null ? fallback : value;
    }
}
