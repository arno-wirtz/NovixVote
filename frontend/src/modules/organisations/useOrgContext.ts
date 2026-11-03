import { useOutletContext } from "react-router-dom";
import type { OrgContext } from "./OrgLayout";

export const useOrgContext = () => useOutletContext<OrgContext>();
