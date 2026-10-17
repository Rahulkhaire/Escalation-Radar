/** Outbound integration failure with retry semantics. */
public class ER_IntegrationException extends Exception {
    public Boolean retryable = false;
    public Integer statusCode;

    public ER_IntegrationException(String message, Boolean retryable, Integer statusCode) {
        this(message);
        this.retryable = retryable;
        this.statusCode = statusCode;
    }
}
