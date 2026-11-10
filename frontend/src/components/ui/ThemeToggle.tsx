import { useTheme } from "../../app/providers/ThemeProvider";
import type { ThemePreference } from "../../services/theme";

const OPTIONS: { value: ThemePreference; label: string }[] = [
  { value: "light", label: "Light" }, { value: "dark", label: "Dark" }, { value: "system", label: "System" },
];

export function ThemeToggle() {
  const { preference, setPreference } = useTheme();
  return (
    <div className="segmented" role="radiogroup" aria-label="Theme">
      {OPTIONS.map((o) => (
        <button key={o.value} type="button" role="radio" aria-checked={preference === o.value}
          className={preference === o.value ? "is-active" : ""} onClick={() => setPreference(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  );
}
