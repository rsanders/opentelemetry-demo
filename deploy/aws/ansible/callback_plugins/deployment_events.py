# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import getpass
import json
import os
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from ansible.plugins.callback import CallbackBase


DOCUMENTATION = r"""
name: deployment_events
type: aggregate
short_description: Emit Ansible deployment lifecycle events to CloudWatch Logs
description:
  - Emits structured deployment started, succeeded, and failed events.
  - Event delivery is best-effort and never changes the playbook result.
requirements:
  - aws CLI
"""


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "deployment_events"
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self):
        super().__init__()
        self._deployment_id = str(uuid.uuid4())
        self._metadata = {}
        self._playbook_dir = None
        self._started = False

    def v2_playbook_on_start(self, playbook):
        self._playbook_dir = Path(playbook._file_name).resolve().parent
        self._metadata = self._git_metadata()

    def v2_playbook_on_play_start(self, play):
        if self._started:
            return

        context = self._deployment_context(play)
        if not context:
            self._display.warning(
                "Deployment event not emitted: app_log_group and aws_region "
                "must be defined in the Ansible inventory"
            )
            return

        variables = context
        self._metadata.update(variables)
        self._metadata["started_unix"] = int(time.time())
        self._metadata["service_version"] = (
            f"{self._metadata['revision']}-{self._metadata['started_unix']}"
        )
        os.environ["OTEL_SERVICE_VERSION"] = self._metadata["service_version"]
        self._started = True
        self._emit("started")

    def v2_playbook_on_stats(self, stats):
        if not self._started:
            return

        failed = any(
            summary.get("failures", 0) or summary.get("unreachable", 0)
            for summary in (stats.summarize(host) for host in stats.processed)
        )
        self._emit("failed" if failed else "succeeded")

    def _deployment_context(self, play):
        variable_manager = play.get_variable_manager()
        hosts = variable_manager._inventory.get_hosts(pattern=play.hosts)
        if not hosts:
            return None

        variables = variable_manager.get_vars(play=play, host=hosts[0])
        log_group = variables.get("app_log_group")
        region = variables.get("aws_region")
        if not log_group or not region:
            return None

        return {
            "log_group": log_group,
            "region": region,
            "project_name": variables.get("project_name", "otel-demo"),
        }

    def _git_metadata(self):
        repo_dir = (self._playbook_dir / "../../..").resolve()

        def git(*args):
            return subprocess.run(
                ["git", "-C", str(repo_dir), *args],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

        try:
            repo_root = Path(git("rev-parse", "--show-toplevel"))
            repo_url = git("remote", "get-url", "origin")
            if repo_url.endswith(".git"):
                repo_url = repo_url[:-4]
            parsed_url = urlsplit(repo_url)
            if parsed_url.scheme in {"http", "https"} and parsed_url.hostname:
                host = parsed_url.hostname
                if ":" in host:
                    host = f"[{host}]"
                netloc = f"{host}:{parsed_url.port}" if parsed_url.port else host
                repo_url = urlunsplit(parsed_url._replace(netloc=netloc))
            branch = git("branch", "--show-current") or "HEAD"
            return {
                "repo_name": repo_root.name,
                "repo_url": repo_url,
                "branch": branch,
                "revision": git("rev-parse", "HEAD"),
                "commit_author": git("log", "-1", "--format=%an"),
                "dirty": bool(git("status", "--porcelain=v1")),
                "deployer": os.environ.get("SUDO_USER") or getpass.getuser(),
            }
        except (OSError, subprocess.CalledProcessError) as exc:
            self._display.warning(f"Could not collect deployment Git metadata: {exc}")
            return {
                "repo_name": repo_dir.name,
                "repo_url": "",
                "branch": "",
                "revision": "",
                "commit_author": "",
                "dirty": False,
                "deployer": os.environ.get("SUDO_USER") or getpass.getuser(),
            }

    def _emit(self, state):
        if state == "started":
            timestamp = datetime.fromtimestamp(
                self._metadata["started_unix"], timezone.utc
            )
        else:
            timestamp = datetime.now(timezone.utc)
        timestamp = timestamp.isoformat().replace("+00:00", "Z")
        failed = state == "failed"
        event = {
            "timestamp": timestamp,
            "severity_number": 17 if failed else 9,
            "severity_text": "ERROR" if failed else "INFO",
            "body": f"Ansible deployment {state}",
            "otel.event.name": f"deployment.{state}",
            "deployment.id": self._deployment_id,
            "deployment.name": f"{self._metadata['project_name']} ansible",
            "cicd.pipeline.name": "ansible",
            "cicd.pipeline.run.id": self._deployment_id,
            "service.name": "ansible",
            "service.namespace": self._metadata["project_name"],
            "service.version": self._metadata["service_version"],
            "vcs.repository.name": self._metadata["repo_name"],
            "vcs.repository.url.full": self._metadata["repo_url"],
            "vcs.ref.head.name": self._metadata["branch"],
            "vcs.ref.head.revision": self._metadata["revision"],
            "vcs.ref.type": "branch",
            "user.name": self._metadata["deployer"],
            "demo.deployment.commit.author.name": self._metadata["commit_author"],
            "demo.deployment.repository.dirty": self._metadata["dirty"],
        }
        if state != "started":
            event["deployment.status"] = state

        log_events = json.dumps(
            [{"timestamp": int(time.time() * 1000), "message": json.dumps(event)}]
        )
        command = [
            "aws",
            "logs",
            "put-log-events",
            "--region",
            self._metadata["region"],
            "--log-group-name",
            self._metadata["log_group"],
            "--log-stream-name",
            "ansible",
            "--log-events",
            log_events,
        ]
        try:
            subprocess.run(command, check=True, capture_output=True, text=True)
        except (OSError, subprocess.CalledProcessError) as exc:
            detail = (
                (exc.stderr or str(exc)).strip()
                if isinstance(exc, subprocess.CalledProcessError)
                else str(exc)
            )
            self._display.warning(f"Could not emit deployment event: {detail}")
