// Reassesses ALL open Cases (use after changing weights/thresholds). Idempotent: one assessment per Case.
Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_REPROCESS, null), 50);
