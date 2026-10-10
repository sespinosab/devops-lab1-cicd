"""Module providing a personalized greeting FastAPI application."""
from fastapi import FastAPI, Query

app = FastAPI(
    title="Greeting API",
    description="DevOps Lab 1 FastAPI Application",
    version="0.2.0",
)


@app.get("/")
def read_greeting(
    first_name: str | None = Query(None, description="First name of the user"),
    last_name: str | None = Query(None, description="Last name of the user"),
):
    """Return personalized greeting or generic prompt.

    Args:
        first_name (str | None): First name query parameter.
        last_name (str | None): Last name query parameter.

    Returns:
        dict: JSON response containing greeting message.
    """
    if first_name and last_name:
        greeting_message = f"Hello, {first_name} {last_name}!"
    else:
        greeting_message = (
            "Hello, World! Please provide your first name and last name "
            "as query parameters."
        )

    return {"message": greeting_message}


@app.get("/health")
def health_check():
    """Health check endpoint for ECS and container monitoring.

    Returns:
        dict: Status dictionary.
    """
    return {"status": "healthy"}
