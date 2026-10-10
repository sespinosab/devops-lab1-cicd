"""Unit tests for the FastAPI greeting application."""
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_greet_user_success():
    """Test greeting with first_name and last_name provided."""
    response = client.get("/?first_name=John&last_name=Doe")
    assert response.status_code == 200
    assert response.json() == {"message": "Hello, John Doe!"}


def test_greet_user_missing_data():
    """Test greeting without query parameters."""
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {
        "message": "Hello, World! Please provide your first name and last name as query parameters."
    }


def test_health_check():
    """Test health check endpoint."""
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "healthy"}
