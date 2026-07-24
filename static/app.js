// Minimal vanilla-JS frontend for the Proxygen auth API.
"use strict";

const $ = (id) => document.getElementById(id);

let mode = "login"; // "login" | "signup"

const els = {
  authView: $("auth-view"),
  userView: $("user-view"),
  tabLogin: $("tab-login"),
  tabSignup: $("tab-signup"),
  form: $("auth-form"),
  username: $("username"),
  password: $("password"),
  submit: $("submit-btn"),
  message: $("message"),
  who: $("who"),
  logout: $("logout-btn"),
};

function setMessage(text, kind) {
  els.message.textContent = text || "";
  els.message.className = "message" + (kind ? " " + kind : "");
}

function setMode(next) {
  mode = next;
  const login = mode === "login";
  els.tabLogin.classList.toggle("active", login);
  els.tabSignup.classList.toggle("active", !login);
  els.submit.textContent = login ? "Log in" : "Sign up";
  setMessage("");
}

function showLoggedIn(username) {
  els.who.textContent = username;
  els.authView.hidden = true;
  els.userView.hidden = false;
}

function showLoggedOut() {
  els.userView.hidden = true;
  els.authView.hidden = false;
  els.form.reset();
}

async function api(path, options) {
  const res = await fetch(path, {
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  let data = {};
  try {
    data = await res.json();
  } catch (_) {
    /* non-JSON response */
  }
  return { ok: res.ok, status: res.status, data };
}

async function refresh() {
  const { ok, data } = await api("/api/me", { method: "GET" });
  if (ok && data.authenticated) {
    showLoggedIn(data.username);
  } else {
    showLoggedOut();
  }
}

els.tabLogin.addEventListener("click", () => setMode("login"));
els.tabSignup.addEventListener("click", () => setMode("signup"));

els.form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const username = els.username.value.trim();
  const password = els.password.value;
  if (!username || !password) {
    setMessage("Please fill in both fields.", "error");
    return;
  }

  els.submit.disabled = true;
  setMessage(mode === "login" ? "Logging in…" : "Creating account…");

  const path = mode === "login" ? "/api/login" : "/api/signup";
  const { ok, data } = await api(path, {
    method: "POST",
    body: JSON.stringify({ username, password }),
  });

  els.submit.disabled = false;

  if (ok && data.ok) {
    setMessage("Success!", "ok");
    showLoggedIn(data.username);
  } else {
    setMessage(data.error || "Something went wrong.", "error");
  }
});

els.logout.addEventListener("click", async () => {
  await api("/api/logout", { method: "POST" });
  setMode("login");
  showLoggedOut();
  setMessage("You have been logged out.", "ok");
});

// On load, check whether an existing session cookie is still valid.
refresh();
