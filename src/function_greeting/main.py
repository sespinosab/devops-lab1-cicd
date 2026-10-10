"""Module providing a personalized greeting Lambda function."""


def lambda_handler(request, context):  # pylint: disable=unused-argument
    """HTTP Lambda Function that accepts a first and last name.

    Args:
        request (Request): The request object containing first_name and
            last_name as query parameters.

    Returns:
        A JSON response with a personalized greeting message.
    """
    # Check if first_name and last_name were provided in the querystring parameters
    query_params = request.get("queryStringParameters") or {}
    if 'first_name' in query_params and 'last_name' in query_params:
        first_name = query_params['first_name']
        last_name = query_params['last_name']
        greeting_message = f"Hello, {first_name} {last_name}!"
    else:
        # If not provided, return a generic message
        greeting_message = (
            "Hello, World! Please provide your first name and last name "
            "as query parameters."
        )

    # Return the greeting message as a JSON response
    return {
        "statusCode": 200,
        "body": {
            "message": greeting_message
        }
    }
