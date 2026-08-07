import PortalPlaceholder from "../../shared/PortalPlaceholder";
export default function MachinePlaceholder(props: { title?: string; description?: string }) {
  return <PortalPlaceholder module="Machine Operation" color="warning" {...props} />;
}
