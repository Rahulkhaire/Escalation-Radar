@IsTest
private class ER_RiskScoringEngineTest {
    private static final Datetime NOW_TS = Datetime.newInstanceGmt(2026, 1, 15, 12, 0, 0);

    private static ER_RiskScoringEngine.Input baseInput() {
        ER_RiskScoringEngine.Input i = new ER_RiskScoringEngine.Input();
        i.now = NOW_TS;
        i.createdDate = NOW_TS;
        i.priority = 'Low';
        i.reopenCount = 0;
        i.accountTier = 'Basic';
        i.slaConsumptionPct = 0;
        i.slaSource = 'TEST';
        return i;
    }

    @IsTest
    static void maximumScoreIsOneHundred() {
        ER_Config.RiskConfig cfg = ER_TestDataFactory.defaultConfig();
        ER_RiskScoringEngine.Input i = baseInput();
        i.priority = 'High';
        i.reopenCount = 10;
        i.accountTier = 'Strategic';
        i.slaConsumptionPct = 150;
        i.createdDate = NOW_TS.addDays(-30);
        i.lastPublicUpdate = NOW_TS.addDays(-10);
        ER_RiskScoringEngine.Result r = ER_RiskScoringEngine.score(i, cfg);
        System.assertEquals(100.0, r.score);
        System.assertEquals(ER_Constants.CAT_CRITICAL, r.category);
        System.assertEquals(5, r.factors.size());
        System.assertEquals('test-1.0', r.ruleVersion);
    }

    @IsTest
    static void emptyInputScoresLowWithoutErrors() {
        ER_Config.RiskConfig cfg = ER_TestDataFactory.defaultConfig();
        ER_RiskScoringEngine.Input i = new ER_RiskScoringEngine.Input();
        i.now = NOW_TS;
        ER_RiskScoringEngine.Result r = ER_RiskScoringEngine.score(i, cfg);
        System.assertEquals(0.0, r.score);
        System.assertEquals(ER_Constants.CAT_LOW, r.category);
        System.assert(r.explanation.contains('No elevated risk factors'));
    }

    @IsTest
    static void slaRampUsesConfiguredStart() {
        ER_Config.RiskConfig cfg = ER_TestDataFactory.defaultConfig();
        ER_RiskScoringEngine.Input i = baseInput();
        i.slaConsumptionPct = 90;
        ER_RiskScoringEngine.Result r = ER_RiskScoringEngine.score(i, cfg);
        ER_RiskScoringEngine.Factor sla = r.factors[0];
        System.assertEquals('SLA', sla.key);
        System.assertEquals(28.0, sla.points); // (90-50)/(100-50) * 35
        System.assert(sla.detail.contains('90.0% consumed'));
        i.slaConsumptionPct = 50;
        System.assertEquals(0.0, ER_RiskScoringEngine.score(i, cfg).factors[0].points);
        i.slaConsumptionPct = null;
        System.assertEquals(0.0, ER_RiskScoringEngine.score(i, cfg).factors[0].points);
    }

    @IsTest
    static void thresholdBoundaries() {
        ER_Config.RiskConfig cfg = ER_TestDataFactory.defaultConfig();
        System.assertEquals('LOW', ER_RiskScoringEngine.categorize(24.9, cfg));
        System.assertEquals('MEDIUM', ER_RiskScoringEngine.categorize(25.0, cfg));
        System.assertEquals('MEDIUM', ER_RiskScoringEngine.categorize(49.9, cfg));
        System.assertEquals('HIGH', ER_RiskScoringEngine.categorize(50.0, cfg));
        System.assertEquals('HIGH', ER_RiskScoringEngine.categorize(74.9, cfg));
        System.assertEquals('CRITICAL', ER_RiskScoringEngine.categorize(75.0, cfg));
    }

    @IsTest
    static void reopenPriorityTierAndEscalation() {
        ER_Config.RiskConfig cfg = ER_TestDataFactory.defaultConfig();
        ER_RiskScoringEngine.Input i = baseInput();
        i.reopenCount = 2;
        ER_RiskScoringEngine.Result r = ER_RiskScoringEngine.score(i, cfg);
        System.assertEquals(10.0, r.factors[2].points); // 2/3 * 15
        System.assert(r.factors[2].detail.contains('reopened 2 times'));
        i.priority = 'Medium';
        i.accountTier = 'Enterprise';
        r = ER_RiskScoringEngine.score(i, cfg);
        System.assertEquals(10.0, r.factors[1].points); // 0.5 * 20
        System.assertEquals(11.3, r.factors[3].points); // 0.75 * 15 = 11.25 -> 11.3
        i.isEscalated = true;
        System.assertEquals(20.0, ER_RiskScoringEngine.score(i, cfg).factors[1].points);
    }

    @IsTest
    static void ageAndStalenessContribute() {
        ER_Config.RiskConfig cfg = ER_TestDataFactory.defaultConfig();
        ER_RiskScoringEngine.Input i = baseInput();
        i.createdDate = NOW_TS.addHours(-36); // 36/72 = 0.5 age
        i.lastPublicUpdate = NOW_TS.addHours(-12); // 12/24 = 0.5 stale
        ER_RiskScoringEngine.Result r = ER_RiskScoringEngine.score(i, cfg);
        System.assertEquals(7.5, r.factors[4].points);
        System.assert(r.explanation.contains('has not received an update'));
    }

    @IsTest
    static void slaCalculatorSuppliedDeadlineAndPolicy() {
        ER_Config.RiskConfig cfg = ER_TestDataFactory.defaultConfig();
        ER_SlaCalculator.SlaResult s = ER_SlaCalculator.compute(NOW_TS.addHours(-9), NOW_TS.addHours(1), 'Low', NOW_TS, cfg, null);
        System.assertEquals(90.0, s.consumptionPct);
        System.assertEquals('SUPPLIED_DEADLINE', s.source);
        s = ER_SlaCalculator.compute(NOW_TS.addHours(-4), null, 'High', NOW_TS, cfg, null);
        System.assertEquals(50.0, s.consumptionPct);
        System.assertEquals('POLICY_CALENDAR_HOURS', s.source);
        s = ER_SlaCalculator.compute(NOW_TS.addHours(-4), null, null, NOW_TS, cfg, null);
        System.assertEquals(null, s.consumptionPct);
        System.assertEquals('NONE', s.source);
    }
}
