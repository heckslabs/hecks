module Hecks
  module Forms
    module Page
      # Decorative only; every form works with JS disabled.
      SCRIPT = <<~JS.freeze
        document.addEventListener("click", (event) => {
          const button = event.target.closest("[data-copy]");
          if (!button) return;
          const text = document.querySelector(button.getAttribute("data-copy"))?.textContent ?? "";
          navigator.clipboard?.writeText(text.trim());
          const original = button.textContent;
          button.textContent = "copied";
          setTimeout(() => { button.textContent = original; }, 1200);
        });
        document.querySelectorAll("[data-money-cents]").forEach((input) => {
          const preview = document.querySelector(input.getAttribute("data-money-cents"));
          if (!preview) return;
          const update = () => {
            const cents = parseInt(input.value, 10);
            preview.textContent = Number.isFinite(cents) ? "= " + (cents / 100).toFixed(2) : "";
          };
          input.addEventListener("input", update);
          update();
        });
      JS
    end
  end
end
