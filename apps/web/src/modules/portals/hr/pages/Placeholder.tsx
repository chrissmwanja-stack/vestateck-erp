import PortalPlaceholder from "../../shared/PortalPlaceholder";
export default function HRPlaceholder(props: { title?: string; description?: string }) {
  return <PortalPlaceholder module="Human Resources" color="success" {...props} />;
}
