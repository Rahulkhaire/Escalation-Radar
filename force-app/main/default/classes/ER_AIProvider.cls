/** Contract for AI adapters. Implementations must throw ER_IntegrationException / ER_AIValidationException only. */
public interface ER_AIProvider {
    ER_AIAnalysis analyze(ER_AIRequest request);
    String name();
}
