import PortalPlaceholder from "../../shared/PortalPlaceholder";
export default function LawPlaceholder(props: { title?: string; description?: string }) {
  return <PortalPlaceholder module="Law and Compliance" color="info" {...props} />;
}
