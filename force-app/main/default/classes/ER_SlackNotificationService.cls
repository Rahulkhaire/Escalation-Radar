/**
 * Optional Slack adapter (incoming webhook through a Named Credential). The webhook URL is a secret: configure it only in the
 * Named Credential. Disabled by default; provider MOCK makes no external call. Duplicate suppression is handled upstream
 * (one open/recent SEND_SLACK_ALERT proposal per Case and category, and approval is always required).
 */
public with sharing class ER_SlackNotificationService {
    public static void send(Id caseId, String correlationId, String text) {
        ER_Config.IntegrationSetting s = ER_Config.slack();
        if (!s.enabled) {
            throw new ER_IntegrationException('Slack integration is disabled.', false, null);
        }
        if (s.provider == 'MOCK') {
            ER_AuditService.logIntegration('SLACK', 'send (mock)', caseId, correlationId, 'Success', 200, 0L, 'Mock Slack adapter: no external call made.', false, 0);
            return;
        }
        if (String.isBlank(s.namedCredential)) {
            throw new ER_IntegrationException('Slack Named Credential is not configured.', false, null);
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + s.namedCredential + (s.endpointPath == null ? '' : s.endpointPath));
        req.setMethod('POST');
        req.setTimeout(Math.min(Math.max(s.timeoutMs, 1000), 120000));
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{ 'text' => ER_AuditService.truncate(text, 3000) }));
        Long t0 = System.currentTimeMillis();
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            ER_AuditService.logIntegration('SLACK', 'send', caseId, correlationId, 'Failure', null, System.currentTimeMillis() - t0, e.getMessage(), true, 0);
            throw new ER_IntegrationException('Slack callout failed: ' + e.getMessage(), true, null);
        }
        Integer code = res.getStatusCode();
        Long dur = System.currentTimeMillis() - t0;
        if (code >= 200 && code < 300) {
            ER_AuditService.logIntegration('SLACK', 'send', caseId, correlationId, 'Success', code, dur, null, false, 0);
            return;
        }
        Boolean retryable = code == 429 || code >= 500;
        String msg = code == 429 ? 'Slack rate limit (HTTP 429), Retry-After ' + res.getHeader('Retry-After') : 'Slack returned HTTP ' + code;
        ER_AuditService.logIntegration('SLACK', 'send', caseId, correlationId, 'Failure', code, dur, msg, retryable, 0);
        throw new ER_IntegrationException(msg, retryable, code);
    }
}
