document.addEventListener("DOMContentLoaded", function () {
  const initUserActionPopups = () => {
    const askConfirm =
      typeof window.showUserActionConfirm === "function"
        ? window.showUserActionConfirm
        : async ({ message = "Подтвердить действие?" } = {}) => window.confirm(message);

    const bindConfirm = (selector, getOptions) => {
      document.querySelectorAll(selector).forEach((form) => {
        form.addEventListener("submit", async (event) => {
          event.preventDefault();
          const confirmed = await askConfirm(getOptions(form));
          if (confirmed) {
            form.submit();
          }
        });
      });
    };

    bindConfirm("form[data-user-action='delete-user']", (form) => {
      const username = form.querySelector("input[name='delete_username']")?.value.trim() || "этого пользователя";
      return {
        title: "Удалить пользователя?",
        message: `Пользователь «${username}» будет удален без возможности восстановления.`,
        confirmText: "Удалить",
        confirmVariant: "danger",
      };
    });

    bindConfirm("form[data-user-action='change-role']", (form) => {
      const username = form.querySelector("input[name='change_role_username']")?.value || "пользователя";
      const role = form.querySelector("select[name='new_role']")?.value || "новую роль";
      return {
        title: "Изменить роль?",
        message: `Для «${username}» будет установлена роль «${role}».`,
        confirmText: "Изменить",
        confirmVariant: "primary",
      };
    });

    bindConfirm("form[data-user-action='change-password']", (form) => {
      const username = form.querySelector("input[name='change_password_username']")?.value || "пользователя";
      return {
        title: "Сменить пароль?",
        message: `Пароль пользователя «${username}» будет обновлен сразу после подтверждения.`,
        confirmText: "Сменить пароль",
        confirmVariant: "danger",
      };
    });
  };
  const initMiniAppLinkCopy = () => {
    const input = document.getElementById("tg-mini-link-input");
    const button = document.getElementById("copy-tg-mini-link-btn");
    const status = document.getElementById("copy-tg-mini-link-status");

    if (!input || !button || !status) {
      return;
    }

    const setStatus = (text, isError = false) => {
      status.textContent = text;
      status.classList.toggle("miniapp-link-status-error", Boolean(isError));
    };

    const fallbackCopy = (text) => {
      input.removeAttribute("readonly");
      input.focus();
      input.select();
      input.setSelectionRange(0, text.length);
      const ok = document.execCommand("copy");
      input.setAttribute("readonly", "readonly");
      return ok;
    };

    button.addEventListener("click", async () => {
      const text = (input.value || "").trim();
      if (!text) {
        setStatus("Ссылка пуста", true);
        return;
      }

      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          await navigator.clipboard.writeText(text);
        } else if (!fallbackCopy(text)) {
          throw new Error("clipboard_unavailable");
        }

        setStatus("Ссылка скопирована");
      } catch {
        setStatus("Не удалось скопировать автоматически. Скопируйте ссылку вручную.", true);
        input.focus();
        input.select();
      }
    });
  };

  const initSettingsRangeControls = () => {
    const formatSecondsHuman = (rawSeconds) => {
      const seconds = Number(rawSeconds);
      if (!Number.isFinite(seconds) || seconds < 0) {
        return "";
      }

      if (seconds < 60) {
        return `${seconds} сек`;
      }

      if (seconds < 3600) {
        const mins = Math.floor(seconds / 60);
        const restSeconds = seconds % 60;
        return restSeconds > 0 ? `${mins} мин ${restSeconds} сек` : `${mins} мин`;
      }

      if (seconds < 86400) {
        const hours = Math.floor(seconds / 3600);
        const restMins = Math.floor((seconds % 3600) / 60);
        return restMins > 0 ? `${hours} ч ${restMins} мин` : `${hours} ч`;
      }

      const days = Math.floor(seconds / 86400);
      const restHours = Math.floor((seconds % 86400) / 3600);
      return restHours > 0 ? `${days} д ${restHours} ч` : `${days} д`;
    };

    const controls = document.querySelectorAll("input[type='range'][data-slider-target]");
    controls.forEach((slider) => {
      const targetId = slider.getAttribute("data-slider-target");
      if (!targetId) return;

      const input = document.getElementById(targetId);
      const valueBadge = document.querySelector(`[data-slider-value-for='${targetId}']`);
      if (!input) return;

      const unit = slider.getAttribute("data-unit") || "";
      const humanize = slider.getAttribute("data-humanize") || "";
      const min = Number(slider.min);
      const max = Number(slider.max);

      const clamp = (raw) => {
        const numeric = Number(raw);
        if (!Number.isFinite(numeric)) {
          return Number.isFinite(min) ? min : 0;
        }

        if (Number.isFinite(min) && numeric < min) {
          return min;
        }
        if (Number.isFinite(max) && numeric > max) {
          return max;
        }
        return numeric;
      };

      const renderLabel = (rawValue) => {
        const numericValue = clamp(rawValue);
        const base = unit ? `${numericValue} ${unit}` : String(numericValue);

        if (humanize === "seconds") {
          const human = formatSecondsHuman(numericValue);
          if (human && human !== base) {
            return `${base} (${human})`;
          }
        }

        return base;
      };

      const applyValue = (rawValue, source) => {
        const normalized = clamp(rawValue);
        slider.value = String(normalized);
        input.value = String(normalized);

        if (valueBadge) {
          valueBadge.textContent = renderLabel(normalized);
        }

        if (source === "input") {
          input.dispatchEvent(new Event("change", { bubbles: true }));
        }
      };

      const initialValue = (input.value || "").trim() || slider.value;
      applyValue(initialValue, "init");

      slider.addEventListener("input", () => {
        applyValue(slider.value, "slider");
      });

      slider.addEventListener("change", () => {
        applyValue(slider.value, "slider");
      });

      input.addEventListener("input", () => {
        const raw = (input.value || "").trim();
        if (!raw) return;
        applyValue(raw, "input");
      });

      input.addEventListener("change", () => {
        const raw = (input.value || "").trim();
        if (!raw) {
          applyValue(slider.value, "input");
          return;
        }
        applyValue(raw, "input");
      });
    });
  };

  initUserActionPopups();
  initMiniAppLinkCopy();
  initSettingsRangeControls();
});
// Обработка перезапуска службы
document
  .getElementById("restartServiceBtn")
  ?.addEventListener("click", function () {
    if (
      confirm(
        "Вы уверены? Служба будет перезапущена на 5-10 секунд.\n\nВо время перезапуска страница будет заблокирована."
      )
    ) {
      startRestartProcess();
    }
  });

function startRestartProcess() {
  const overlay = document.getElementById("loadingOverlay");
  const countdownElement = document.getElementById("countdownTimer");

  overlay.style.display = "flex";
  requestAnimationFrame(() => {
    overlay.classList.add("is-open");
  });

  let countdown = 5;

  const countdownInterval = setInterval(() => {
    countdown--;
    countdownElement.textContent = countdown;

    if (countdown <= 0) {
      clearInterval(countdownInterval);

      document.querySelector(".loading-title").textContent =
        "⚡ Выполняется перезапуск...";
      document.querySelector(".loading-message").textContent =
        "Выполняется команда перезапуска службы.";
      countdownElement.style.display = "none";

      setTimeout(async () => {
        try {
          const resp = await fetch("/api/restart-service", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-CSRFToken": window.getCsrfToken(),
            },
          });
          const data = await resp.json();
          if (data.queued && data.task_id) {
            await pollBackgroundTask(data.task_id, {
              maxConsecutiveErrors: 5,
              timeoutMs: 120000,
            });
          }
        } catch {
          // Ошибки во время перезапуска ожидаемы — перезагружаем страницу
        }
        window.location.reload();
      }, 1000);
    }
  }, 1000);

  document.body.style.overflow = "hidden";
  countdownElement.classList.add("pulse");
}

// Заблокировать клавиши во время загрузки
document.addEventListener(
  "keydown",
  function (e) {
    const overlay = document.getElementById("loadingOverlay");
    if (overlay && overlay.style.display === "flex") {
      e.preventDefault();
      return false;
    }
  },
  false
);

// Заблокировать клики по странице во время загрузки
document.addEventListener(
  "click",
  function (e) {
    const overlay = document.getElementById("loadingOverlay");
    if (overlay && overlay.style.display === "flex") {
      e.preventDefault();
      e.stopPropagation();
      return false;
    }
  },
  true
);
