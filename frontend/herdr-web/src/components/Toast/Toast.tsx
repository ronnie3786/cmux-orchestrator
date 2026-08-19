import { useToastStore } from "../../lib/toast";
import "./toast.css";

/**
 * Toast host (iOS ToastView parity): a single top-of-screen capsule,
 * role="status"; the 2.2 s auto-dismiss timer lives in the toast store.
 */
export function Toast() {
  const message = useToastStore((state) => state.message);
  if (message === null) return null;
  return (
    <div className="hz-toast" role="status">
      {message}
    </div>
  );
}
