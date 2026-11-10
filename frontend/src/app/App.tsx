import { Navigate, Route, Routes } from "react-router-dom";
import { AppShell } from "../layouts/AppShell";
import { LoginPage } from "../modules/authentication/LoginPage";
import { RequireAuth } from "../modules/authentication/RequireAuth";
import { DashboardPage } from "../modules/dashboard/DashboardPage";
import { BallotPage } from "../modules/elections/BallotPage";
import { ElectionLayout } from "../modules/elections/ElectionLayout";
import { ElectionOverviewPage } from "../modules/elections/ElectionOverviewPage";
import { VoterElectionPage } from "../modules/elections/VoterElectionPage";
import { VotersPage } from "../modules/elections/VotersPage";
import { ElectionFormPage } from "../modules/elections/ElectionFormPage";
import { ElectionsPage } from "../modules/elections/ElectionsPage";
import { MembersPage } from "../modules/members/MembersPage";
import { OrgLayout } from "../modules/organisations/OrgLayout";
import { WorkspacesPage } from "../modules/organisations/WorkspacesPage";

export function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route element={<RequireAuth><AppShell /></RequireAuth>}>
        <Route path="/dashboard" element={<DashboardPage />} />
        <Route path="/workspaces" element={<WorkspacesPage />} />
        <Route path="/elections/:electionId" element={<VoterElectionPage />} />
        <Route path="/workspaces/:orgId" element={<OrgLayout />}>
          <Route index element={<Navigate to="elections" replace />} />
          <Route path="elections" element={<ElectionsPage />} />
          <Route path="elections/new" element={<ElectionFormPage />} />
          <Route path="elections/:electionId/edit" element={<ElectionFormPage />} />
          <Route path="elections/:electionId" element={<ElectionLayout />}>
            <Route index element={<ElectionOverviewPage />} />
            <Route path="ballot" element={<BallotPage />} />
            <Route path="voters" element={<VotersPage />} />
          </Route>
          <Route path="members" element={<MembersPage />} />
        </Route>
      </Route>
      <Route path="*" element={<Navigate to="/dashboard" replace />} />
    </Routes>
  );
}
