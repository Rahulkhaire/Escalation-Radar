// Backfills assessments for existing open Cases that have none (bounded batch, scope 50).
Database.executeBatch(new ER_RiskAssessmentBatch(ER_RiskAssessmentBatch.MODE_INITIAL, null), 50);
