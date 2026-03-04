# This project is an independent open-source initiative and is not affiliated with, endorsed by, or supported by Cisco Systems, Inc. or Duo Security.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

from flask import Flask, request, render_template_string, session, redirect, url_for
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from flask_wtf.csrf import CSRFProtect
from ldap3 import Server, Connection, ALL, SASL, Tls
import os
import ssl
import re
import tempfile
import requests
import time
import hashlib
import hmac
import base64
import gssapi
import logging
from datetime import timedelta
from urllib.parse import urlencode
from duo_universal.client import Client, DuoException

# Set logging to INFO
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Init Flask
app = Flask(__name__)
app.secret_key = os.getenv('FLASK_SECRET_KEY')
if not app.secret_key:
    raise RuntimeError("FLASK_SECRET_KEY environment variable must be set.")
app.permanent_session_lifetime = timedelta(minutes=15)

# Init CSRF 
app.config['WTF_CSRF_SSL_STRICT'] = False
csrf = CSRFProtect(app)

# Duo Admin API configuration for bypass
IKEY = os.getenv('DUO_IKEY')
SKEY = os.getenv('DUO_SKEY')
HOST = os.getenv('DUO_HOST')

# Duo MFA (Web SDK) configuration for login authentication
DUO_CLIENT_ID = os.getenv('DUO_CLIENT_ID')
DUO_CLIENT_SECRET = os.getenv('DUO_CLIENT_SECRET')
DUO_API_HOST = os.getenv('DUO_API_HOST')
DUO_REDIRECT_URI = os.getenv('DUO_REDIRECT_URI')

duo_client = None
if DUO_CLIENT_ID and DUO_CLIENT_SECRET and DUO_API_HOST:
    if not DUO_REDIRECT_URI:
        logger.error("DUO_REDIRECT_URI environment variable must be set when Duo MFA is enabled.")
    else:
        try:
            duo_client = Client(
                client_id=DUO_CLIENT_ID,
                client_secret=DUO_CLIENT_SECRET,
                host=DUO_API_HOST,
                redirect_uri=DUO_REDIRECT_URI
            )
            duo_client.health_check()
            logger.info("Duo Universal Client initialized and healthy.")
        except DuoException as e:
            logger.error(f"Duo MFA client health check failed: {e}")
            duo_client = None
else:
    logger.warning("Duo MFA client credentials not configured. MFA will be skipped.")

# Config for LDAPS with Kerberos
TLS_CONFIG = Tls(
    validate=ssl.CERT_NONE,
    ca_certs_file='/path/to/your/ca-chain.pem',
    version=ssl.PROTOCOL_TLSv1_2
)

LDAP_SERVER = 'ldaps://your.ad.server'
LDAP_PORT = 636
KERBEROS_REALM = 'YOURDOMAIN.COM'
LDAP_SEARCH_BASE = 'DC=your,DC=domain,DC=com'

# Duo Bypass API call config
MAX_BYPASS_DURATION_SECONDS = 86400
DEFAULT_BYPASS_DURATION_SECONDS = 3600

BYPASS_DURATION_OPTIONS = {
    '15m': 900,
    '30m': 1800,
    '1h': 3600,
    '2h': 7200,
    '4h': 14400,
    '8h': 28800,
    '12h': 43200,
    '24h': 86400,
}

# Username for web frontend sanitization
def sanitize_username(username):
    if not username or len(username) > 64:
        return None
    if not re.match(r'^[a-zA-Z0-9._-]+$', username):
        return None
    return username

# Authenticate user to web frontend
def authenticate_user(username, password):
    principal = f'{username}@{KERBEROS_REALM}'
    ccache_file = None

    try:
        name = gssapi.Name(principal, gssapi.NameType.kerberos_principal)
        acquire_result = gssapi.raw.acquire_cred_with_password(
            name,
            password.encode(),
            usage='initiate'
        )

        fd, ccache_file = tempfile.mkstemp(prefix='krb5cc_')
        os.close(fd)

        gssapi.raw.store_cred_into(
            {b'ccache': ccache_file.encode()},
            acquire_result.creds,
            usage='initiate',
            overwrite=True
        )

        store = {b'ccache': ccache_file.encode()}
        creds_from_cache = gssapi.Credentials(
            usage='initiate',
            name=name,
            store=store
        )

        server = Server(
            LDAP_SERVER,
            port=LDAP_PORT,
            use_ssl=True,
            tls=TLS_CONFIG,
            get_info=ALL
        )

        conn = Connection(
            server,
            authentication=SASL,
            sasl_mechanism='GSSAPI',
            sasl_credentials=(None, None, creds_from_cache,),
            auto_bind=True
        )

        authenticated = conn.bound
        if authenticated:
            conn.unbind()

        return authenticated

    except gssapi.exceptions.GSSError:
        return False
    except Exception as e:
        logger.error(f"LDAP GSSAPI bind failed for user '{username}': {e}")
        return False
    finally:
        if ccache_file:
            try:
                os.remove(ccache_file)
            except OSError:
                pass

# Create HMAC-SHA1 auth signature for Duo Admin API requests
def sign_request(method, host, path, params, ikey, skey):
    date = time.strftime('%a, %d %b %Y %H:%M:%S -0000', time.gmtime())
    canon = '\n'.join([
        date,
        method.upper(),
        host.lower(),
        path,
        urlencode(sorted(params.items()))
    ])
    sig = hmac.new(skey.encode(), canon.encode(), hashlib.sha1)
    auth = f'{ikey}:{sig.hexdigest()}'
    return base64.b64encode(auth.encode()).decode(), date

# Get Duo user id based on username entered in authentication to web frontend
def get_duo_user_id(username):
    method = 'GET'
    path = '/admin/v1/users'
    url = f'https://{HOST}{path}'

    params = {
        'username': username,
    }

    auth, date = sign_request(method, HOST, path, params, IKEY, SKEY)

    headers = {
        'Date': date,
        'Authorization': f'Basic {auth}',
    }

    try:
        response = requests.get(url, params=params, headers=headers, timeout=10)
        if response.status_code == 200:
            data = response.json()
            users = data.get('response', [])
            if users:
                return users[0].get('user_id')
            else:
                logger.error(f"No Duo user found for '{username}'")
        else:
            logger.error(f"Duo user lookup error for '{username}': {response.status_code} - {response.text}")
    except requests.exceptions.RequestException as e:
        logger.error(f"Duo user lookup request failed: {e}")

    return None

# Request a Duo bypass code based on user selected configuration
def request_bypass_code(username, duration_seconds=DEFAULT_BYPASS_DURATION_SECONDS):
    if duration_seconds < 1:
        duration_seconds = DEFAULT_BYPASS_DURATION_SECONDS
    if duration_seconds > MAX_BYPASS_DURATION_SECONDS:
        duration_seconds = MAX_BYPASS_DURATION_SECONDS

    user_id = get_duo_user_id(username)
    if not user_id:
        logger.error(f"Could not find Duo user_id for '{username}'")
        return None, None

    method = 'POST'
    path = f'/admin/v1/users/{user_id}/bypass_codes'
    url = f'https://{HOST}{path}'

    params = {
        'count': '1',
        'valid_secs': str(duration_seconds),
    }

    auth, date = sign_request(method, HOST, path, params, IKEY, SKEY)

    headers = {
        'Date': date,
        'Authorization': f'Basic {auth}',
        'Content-Type': 'application/x-www-form-urlencoded'
    }

    try:
        response = requests.post(url, data=params, headers=headers, timeout=10)
        if response.status_code == 200:
            data = response.json()
            codes = data.get('response', [])
            if codes:
                return codes[0], duration_seconds
        else:
            logger.error(f"Duo bypass code error for '{username}': {response.status_code} - {response.text}")
    except requests.exceptions.RequestException as e:
        logger.error(f"Duo API request failed: {e}")

    return None, None

# Formats user selected duration sent to Duo Admin API
def format_duration(seconds):
    hours, remainder = divmod(seconds, 3600)
    minutes = remainder // 60
    if hours and minutes:
        return f"{hours}h {minutes}m"
    elif hours:
        return f"{hours}h"
    elif minutes:
        return f"{minutes}m"
    else:
        return f"{seconds}s"

# Session limit config
@app.before_request
def make_session_permanent():
    session.permanent = True

limiter = Limiter(
    get_remote_address,
    app=app,
    default_limits=[],
    storage_uri="memory://",
)

# Flask login POST
@app.route('/', methods=['GET', 'POST'])
@limiter.limit("5 per minute", methods=["POST"])
def login():
    error = None

    if request.method == 'POST':
        raw_username = request.form.get('username', '')
        password = request.form.get('password', '')

        username = sanitize_username(raw_username)
        if not username:
            error = "Invalid username format."
        else:
            try:
                if authenticate_user(username, password):
                    # AD authentication successful
                    if duo_client:
                        # Store username in session for MFA flow
                        session['pending_mfa_username'] = username
                        session['mfa_state'] = os.urandom(16).hex()

                        # Generate the Duo auth URL
                        try:
                            duo_auth_url = duo_client.create_auth_url(
                                username=username,
                                state=session['mfa_state']
                            )
                            return redirect(duo_auth_url)
                        except DuoException as e:
                            logger.error(f"Duo MFA auth URL creation failed: {e}")
                            error = "MFA service unavailable. Please try again later."
                    else:
                        # No Duo MFA configured, grant access directly
                        logger.warning(f"Duo MFA not configured. Granting direct access for '{username}'.")
                        session['username'] = username
                        return redirect(url_for('bypass_code'))
                else:
                    error = "Invalid credentials. Please try again."
            except Exception:
                error = "Authentication failed. Please try again."

    return render_template_string('''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Duo Bypass - Login</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
    <link rel="icon" type="image/png" href="{{ url_for('static', filename='images/favicon.png') }}">
</head>
<body>
    <div class="banner">
        <img src="{{ url_for('static', filename='images/banner.jpg') }}" alt="Banner">
    </div>

    <div class="logo-container">
        <img src="{{ url_for('static', filename='images/logo.png') }}" alt="Logo">
    </div>

    <div class="card">
        <h2>Sign In</h2>

        {% if error %}
        <div class="error-message">{{ error }}</div>
        {% endif %}

        <form method="post">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}" />

            <div class="form-group">
                <label for="username">Username</label>
                <input id="username" name="username" type="text" placeholder="Enter your AD username" required autofocus />
            </div>

            <div class="form-group">
                <label for="password">Password</label>
                <input id="password" name="password" type="password" placeholder="Enter your password" required />
            </div>

            <button type="submit" class="btn">Sign In</button>
        </form>
    </div>

    <div class="footer">
        Duo Bypass Code Generator
    </div>
</body>
</html>
    ''', error=error)

# Duo MFA callback route in Flask if Duo MFA enabled
@app.route('/duo-callback')
def duo_callback():
    # Verify we have a pending MFA session
    pending_username = session.get('pending_mfa_username')
    expected_state = session.get('mfa_state')

    if not pending_username or not expected_state:
        logger.warning("Duo callback received without pending MFA session.")
        return redirect(url_for('login'))

    # Get the state and code from Duo's redirect
    state = request.args.get('state', '')
    duo_code = request.args.get('duo_code', '')

    # Verify state matches to prevent CSRF
    if state != expected_state:
        logger.warning(f"Duo MFA state mismatch for '{pending_username}'.")
        session.pop('pending_mfa_username', None)
        session.pop('mfa_state', None)
        return render_template_string('''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Duo Bypass - MFA Error</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
    <link rel="icon" type="image/png" href="{{ url_for('static', filename='images/favicon.png') }}">
</head>
<body>
    <div class="banner">
        <img src="{{ url_for('static', filename='images/banner.jpg') }}" alt="Banner">
    </div>

    <div class="logo-container">
        <img src="{{ url_for('static', filename='images/logo.png') }}" alt="Logo">
    </div>

    <div class="card">
        <h2>MFA Verification Failed</h2>
        <div class="error-message">Security validation failed. Please try again.</div>
        <div class="link-group">
            <a href="{{ url_for('login') }}">Return to Login</a>
        </div>
    </div>

    <div class="footer">
        Duo Bypass Code Generator
    </div>
</body>
</html>
        '''), 403

    # Exchange the duo_code for token to verify authentication
    try:
        decoded_token = duo_client.exchange_authorization_code_for_2fa_result(
            duoCode=duo_code,
            username=pending_username
        )

        # Verify the token contains the expected username
        auth_username = decoded_token.get('preferred_username', '')
        if auth_username.lower() != pending_username.lower():
            logger.warning(f"Duo MFA username mismatch: expected '{pending_username}', got '{auth_username}'.")
            session.pop('pending_mfa_username', None)
            session.pop('mfa_state', None)
            return redirect(url_for('login'))

        # MFA successful - grant full session
        logger.info(f"Duo MFA successful for '{pending_username}'.")
        session.pop('pending_mfa_username', None)
        session.pop('mfa_state', None)
        session['username'] = pending_username
        return redirect(url_for('bypass_code'))

    except DuoException as e:
        logger.error(f"Duo MFA verification failed for '{pending_username}': {e}")
        session.pop('pending_mfa_username', None)
        session.pop('mfa_state', None)

        return render_template_string('''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Duo Bypass - MFA Failed</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
    <link rel="icon" type="image/png" href="{{ url_for('static', filename='images/favicon.png') }}">
</head>
<body>
    <div class="banner">
        <img src="{{ url_for('static', filename='images/banner.jpg') }}" alt="Banner">
    </div>

    <div class="logo-container">
        <img src="{{ url_for('static', filename='images/logo.png') }}" alt="Logo">
    </div>

    <div class="card">
        <h2>MFA Verification Failed</h2>
        <div class="error-message">Duo authentication was not completed successfully. Please try again.</div>
        <div class="link-group">
            <a href="{{ url_for('login') }}">Return to Login</a>
        </div>
    </div>

    <div class="footer">
        Duo Bypass Code Generator
    </div>
</body>
</html>
        '''), 401

    except Exception as e:
        logger.error(f"Unexpected error during Duo MFA for '{pending_username}': {e}")
        session.pop('pending_mfa_username', None)
        session.pop('mfa_state', None)
        return redirect(url_for('login'))

# Flask route for bypass config selection by user
@app.route('/bypass_code', methods=['GET', 'POST'])
@limiter.limit("10 per hour", methods=["POST"])
def bypass_code():
    if 'username' not in session:
        return redirect(url_for('login'))

    username = session['username']

    if request.method == 'POST':
        selected_duration = request.form.get('duration', '')
        if selected_duration not in BYPASS_DURATION_OPTIONS:
            return render_template_string(BYPASS_ERROR_TEMPLATE,
                username=username, error="Invalid duration selected.")

        duration_seconds = BYPASS_DURATION_OPTIONS[selected_duration]
        code, valid_for = request_bypass_code(username, duration_seconds)

        if code:
            expiry_display = format_duration(valid_for)
            resp = app.make_response(
                render_template_string('''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Duo Bypass - Code Generated</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
    <link rel="icon" type="image/png" href="{{ url_for('static', filename='images/favicon.png') }}">
</head>
<body>
    <div class="banner">
        <img src="{{ url_for('static', filename='images/banner.jpg') }}" alt="Banner">
    </div>

    <div class="logo-container">
        <img src="{{ url_for('static', filename='images/logo.png') }}" alt="Logo">
    </div>

    <div class="card">
        <h2>Bypass Code Generated</h2>

        <div class="success-message">Code generated successfully!</div>

        <div class="code-display">
            <div class="code-meta">Bypass code for <strong>{{ username }}</strong></div>
            <div class="code-value">{{ code }}</div>
            <div class="code-meta">Valid for <strong>{{ expiry_display }}</strong></div>
        </div>

        <div class="link-group">
            <a href="{{ url_for('bypass_code') }}">Generate Another Code</a>
            <a href="{{ url_for('logout') }}">Logout</a>
        </div>
    </div>

    <div class="footer">
        Duo Bypass Code Generator
    </div>
</body>
</html>
                ''', username=username, code=code, expiry_display=expiry_display)
            )
            resp.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
            resp.headers['Pragma'] = 'no-cache'
            return resp
        else:
            return render_template_string('''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Duo Bypass - Error</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
    <link rel="icon" type="image/png" href="{{ url_for('static', filename='images/favicon.png') }}">
</head>
<body>
    <div class="banner">
        <img src="{{ url_for('static', filename='images/banner.jpg') }}" alt="Banner">
    </div>

    <div class="logo-container">
        <img src="{{ url_for('static', filename='images/logo.png') }}" alt="Logo">
    </div>

    <div class="card">
        <h2>Error</h2>
        <div class="error-message">Failed to generate bypass code. Please try again.</div>

        <div class="link-group">
            <a href="{{ url_for('bypass_code') }}">Try Again</a>
            <a href="{{ url_for('logout') }}">Logout</a>
        </div>
    </div>

    <div class="footer">
        Duo Bypass Code Generator
    </div>
</body>
</html>
            '''), 500

    return render_template_string('''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Duo Bypass - Generate Code</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
    <link rel="icon" type="image/png" href="{{ url_for('static', filename='images/favicon.png') }}">
</head>
<body>
    <div class="banner">
        <img src="{{ url_for('static', filename='images/banner.jpg') }}" alt="Banner">
    </div>

    <div class="logo-container">
        <img src="{{ url_for('static', filename='images/logo.png') }}" alt="Logo">
    </div>

    <div class="card">
        <h2>Generate Bypass Code</h2>

        <p class="info-text">Generating code for <strong>{{ username }}</strong></p>

        <form method="post">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}" />

            <div class="radio-group">
                <span class="radio-group-label">Code valid for:</span>
                {% for label, seconds in options.items() %}
                <span class="radio-option">
                    <input type="radio" id="dur_{{ label }}" name="duration" value="{{ label }}"
                        {{ 'checked' if label == default else '' }} />
                    <label for="dur_{{ label }}">{{ label }}</label>
                </span>
                {% endfor %}
            </div>

            <button type="submit" class="btn">Generate Bypass Code</button>
        </form>

        <div class="link-group">
            <a href="{{ url_for('logout') }}">Logout</a>
        </div>
    </div>

    <div class="footer">
        Duo Bypass Code Generator
    </div>
</body>
</html>
    ''', username=username, options=BYPASS_DURATION_OPTIONS, default='1h')

# Flask route for logging out
@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

# Security headers
@app.after_request
def set_security_headers(response):
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['Content-Security-Policy'] = "default-src 'self'; img-src 'self'; style-src 'self'; form-action 'self' https://*.duosecurity.com"
    response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
    return response

# Main
if __name__ == '__main__':
    if IKEY and SKEY and HOST:
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.minimum_version = ssl.TLSVersion.TLSv1_2
        ssl_context.load_cert_chain(
            certfile='/path/to/cert.pem',
            keyfile='/path/to/key.pem'
        )
        app.run(
            host='0.0.0.0',
            port=443,
            ssl_context=ssl_context,
            debug=False
        )