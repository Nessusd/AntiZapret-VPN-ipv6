document.addEventListener("DOMContentLoaded", () => {
  const root = document.getElementById("antizapret-config");
  if (!root) return;

  const stateLabels = {
    unsaved: "изменено",
    pending: "требуется применить",
    applied: "применено",
    idle: "актуально",
  };

  let schema = [];
  let baseline = new Map();
  let hasUnsavedChanges = false;
  let needsApply = false;

  const csrfToken = () => {
    if (typeof window.getCsrfToken === "function") return window.getCsrfToken();
    return document.querySelector('meta[name="csrf-token"]')?.content || "";
  };

  const controlValue = (control) =>
    control.type === "checkbox" ? control.checked : control.value;

  const editableControls = () =>
    Array.from(root.querySelectorAll("input, select, textarea")).filter(
      (control) => control.type !== "hidden" && !control.disabled
    );

  const setSectionStatus = (state, sectionName = null) => {
    const label = stateLabels[state] || stateLabels.idle;
    const selector = sectionName
      ? `[data-section-status="${sectionName}"]`
      : "[data-section-status]";

    document.querySelectorAll(selector).forEach((badge) => {
      badge.textContent = label;
      badge.classList.remove("state-unsaved", "state-pending", "state-applied", "state-idle");
      badge.classList.add(`state-${state}`);
    });
  };

  const setWorkbenchState = (state) => {
    const label = stateLabels[state] || stateLabels.idle;
    ["workbench-dirty-state", "sticky-dirty-status"].forEach((id) => {
      const element = document.getElementById(id);
      if (!element) return;
      element.textContent = label.charAt(0).toUpperCase() + label.slice(1);
      element.classList.remove(
        "workbench-state-unsaved",
        "workbench-state-pending",
        "workbench-state-applied"
      );
      element.classList.add(`workbench-state-${state}`);
    });
  };

  const updateActionSurface = () => {
    const sticky = document.getElementById("settingsStickyActions");
    const saveButton = document.getElementById("sticky-save");
    const cancelButton = document.getElementById("sticky-cancel");
    const applyButton = document.getElementById("sticky-apply");
    const primaryApplyButton = document.getElementById("workbench-primary-apply");

    if (sticky) sticky.hidden = !hasUnsavedChanges && !needsApply;
    if (saveButton) saveButton.disabled = !hasUnsavedChanges;
    if (cancelButton) cancelButton.disabled = !hasUnsavedChanges;
    if (applyButton) applyButton.disabled = !hasUnsavedChanges && !needsApply;
    if (primaryApplyButton) primaryApplyButton.disabled = !hasUnsavedChanges && !needsApply;

    setWorkbenchState(hasUnsavedChanges ? "unsaved" : needsApply ? "pending" : "applied");
  };

  const refreshBaseline = () => {
    baseline = new Map(editableControls().map((control) => [control, controlValue(control)]));
    hasUnsavedChanges = false;
    updateActionSurface();
  };

  const updateDirtyState = (changedControl) => {
    hasUnsavedChanges = Array.from(baseline).some(
      ([control, initialValue]) => controlValue(control) !== initialValue
    );

    const sectionName = changedControl
      ?.closest("[data-antizapret-group]")
      ?.getAttribute("data-antizapret-group");
    if (sectionName) setSectionStatus(hasUnsavedChanges ? "unsaved" : "applied", sectionName);
    updateActionSurface();
  };

  const initializeDetails = () => {
    root.querySelectorAll(".config-item-tooltip").forEach((tooltip) => {
      if (tooltip.parentElement?.classList.contains("config-item-details")) return;

      const details = document.createElement("details");
      details.className = "config-item-details";
      const summary = document.createElement("summary");
      summary.textContent = "Подробнее";
      details.appendChild(summary);
      tooltip.classList.add("config-item-tooltip--details");
      tooltip.parentNode.insertBefore(details, tooltip);
      details.appendChild(tooltip);
    });
  };

  const showStatus = (message, level = "info") => {
    const status = document.getElementById("config-status");
    if (!status) return;
    status.textContent = message;
    status.className = `notification notification-${level} notification-inline-progress`;
    status.hidden = false;
    status.style.display = "block";
  };

  const hideStatus = () => {
    const status = document.getElementById("config-status");
    if (!status) return;
    status.hidden = true;
    status.textContent = "";
    status.style.display = "none";
  };

  const fetchJson = async (url, options = {}) => {
    const response = await fetch(url, options);
    const payload = await response.json();
    if (!response.ok || payload.success === false) {
      throw new Error(payload.message || `Ошибка HTTP ${response.status}`);
    }
    return payload;
  };

  const loadSettings = async () => {
    try {
      if (!schema.length) {
        const schemaPayload = await fetchJson("/antizapret_settings_schema", { cache: "no-store" });
        schema = Array.isArray(schemaPayload) ? schemaPayload : [];
      }
      const values = await fetchJson("/get_antizapret_settings", { cache: "no-store" });

      schema.forEach((field) => {
        const control = document.getElementById(field.html_id);
        if (!control) return;
        const value = values[field.key];
        if (field.type === "flag") control.checked = value === "y";
        else control.value = value || "";
        if (field.managed_by_installer) {
          control.disabled = true;
          control.dataset.managedByInstaller = "true";
        }
      });

      if (!needsApply) setSectionStatus("idle");
      refreshBaseline();
    } catch (error) {
      window.showNotification?.(`Ошибка загрузки настроек: ${error.message}`, "error");
    }
  };

  const applySettings = async () => {
    showStatus("Применение изменений...", "info");
    const payload = await fetchJson("/run-doall", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRFToken": csrfToken(),
      },
      body: JSON.stringify({ context: "Применение настроек AntiZapret" }),
    });

    if (payload.queued && payload.task_id) {
      const poller = window.pollBackgroundTaskWithProgress || window.pollBackgroundTask;
      if (typeof poller !== "function") {
        throw new Error("Не удалось отследить фоновое применение настроек");
      }
      const task = await poller(payload.task_id, {
        timeoutMs: 900000,
        title: "Применение настроек AntiZapret…",
      });
      if (task.status && task.status !== "completed") {
        throw new Error(task.error || task.message || "Применение завершилось с ошибкой");
      }
    }

    needsApply = false;
    setSectionStatus("applied");
    window.showNotification?.("Изменения применены.", "success");
  };

  const saveSettings = async ({ apply = false } = {}) => {
    if (!schema.length) await loadSettings();
    if (!schema.length) return;
    const values = {};

    schema.forEach((field) => {
      if (field.managed_by_installer) return;
      const control = document.getElementById(field.html_id);
      if (!control) return;
      values[field.key] = field.type === "flag"
        ? (control.checked ? "y" : "n")
        : control.value.trim();
    });

    showStatus("Сохранение настроек...", "info");
    try {
      const result = await fetchJson("/update_antizapret_settings", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRFToken": csrfToken(),
        },
        body: JSON.stringify(values),
      });

      if (Number(result.changes || 0) > 0) needsApply = true;
      refreshBaseline();

      if (apply && needsApply) {
        await applySettings();
      } else if (needsApply) {
        setSectionStatus("pending");
        window.showNotification?.(
          "Настройки сохранены. Нажмите «Применить» для запуска изменений.",
          "success"
        );
      } else {
        setSectionStatus("applied");
        window.showNotification?.("Изменений нет.", "info");
      }
    } catch (error) {
      window.showNotification?.(`Ошибка: ${error.message}`, "error");
    } finally {
      hideStatus();
      updateActionSurface();
    }
  };

  const applyPending = async () => {
    try {
      await applySettings();
    } catch (error) {
      needsApply = true;
      setSectionStatus("pending");
      window.showNotification?.(`Ошибка: ${error.message}`, "error");
    } finally {
      hideStatus();
      updateActionSurface();
    }
  };

  editableControls().forEach((control) => {
    control.addEventListener("input", () => updateDirtyState(control));
    control.addEventListener("change", () => updateDirtyState(control));
  });

  document.getElementById("sticky-save")?.addEventListener("click", () => saveSettings());
  document.getElementById("sticky-cancel")?.addEventListener("click", loadSettings);
  document.getElementById("sticky-apply")?.addEventListener("click", () => {
    if (hasUnsavedChanges) saveSettings({ apply: true });
    else if (needsApply) applyPending();
  });
  document.getElementById("workbench-primary-apply")?.addEventListener("click", () => {
    if (hasUnsavedChanges) saveSettings({ apply: true });
    else if (needsApply) applyPending();
  });

  initializeDetails();
  updateActionSurface();
  loadSettings();
  window.loadAntizapretSettings = loadSettings;
});
