from flask import Flask
import os

app = Flask(__name__)
VERSION = os.environ.get("APP_VERSION", "dev")


@app.get("/")
def index():
    return (
        f"<h1>demo-app</h1>"
        f"<p>GitOps lab running on Kind.</p>"
        f"<p>Version: {VERSION}</p>"
    )


@app.get("/healthz")
def healthz():
    return {"status": "ok", "version": VERSION}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
